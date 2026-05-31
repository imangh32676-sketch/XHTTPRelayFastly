param(
  [switch]$SkipNodeInstall
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { $PSDefaultParameterValues['Invoke-WebRequest:UseBasicParsing'] = $true } catch {}

$NpmExe = "npm.cmd"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

try {
  [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {}

# ─────────────────────────────────────────────
#  UI helpers
# ─────────────────────────────────────────────
function Write-Banner {
  Clear-Host
  Write-Host "==============================================" -ForegroundColor Cyan
  Write-Host " XHTTPRelayECO  >>  Fastly Compute Deployer  " -ForegroundColor Cyan
  Write-Host " by @b3hnamrjd                               " -ForegroundColor Cyan
  Write-Host " Telegram : https://t.me/B3hnamR             " -ForegroundColor Cyan
  Write-Host " GitHub   : https://github.com/B3hnamR       " -ForegroundColor Cyan
  Write-Host "==============================================" -ForegroundColor Cyan
  Write-Host ""
}

function Write-Step([string]$Text) {
  Write-Host ""
  Write-Host ">> $Text" -ForegroundColor Yellow
}

function Write-OK([string]$Text)   { Write-Host "   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "   $Text" -ForegroundColor Cyan }
function Write-Warn([string]$Text) { Write-Host "   $Text" -ForegroundColor DarkYellow }
function Write-Err([string]$Text)  { Write-Host "   $Text" -ForegroundColor Red }

function Read-Default([string]$Prompt, [string]$DefaultValue) {
  $raw = Read-Host "$Prompt [$DefaultValue]"
  if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
  return $raw.Trim()
}

function Read-Required([string]$Prompt) {
  while ($true) {
    $raw = Read-Host $Prompt
    if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw.Trim() }
    Write-Err "Required - please enter a value."
  }
}

function Read-YesNo([string]$Prompt, [bool]$DefaultYes = $true) {
  $def = if ($DefaultYes) { "Y/n" } else { "y/N" }
  while ($true) {
    $v = Read-Host "$Prompt ($def)"
    if ([string]::IsNullOrWhiteSpace($v)) { return $DefaultYes }
    $x = $v.Trim().ToLowerInvariant()
    if ($x -eq "y" -or $x -eq "yes") { return $true }
    if ($x -eq "n" -or $x -eq "no")  { return $false }
    Write-Err "Please enter y or n."
  }
}

function Normalize-Path([string]$p) {
  $p = ([string]$p).Trim()
  if ([string]::IsNullOrWhiteSpace($p)) { return "/api" }
  if (-not $p.StartsWith("/")) { $p = "/$p" }
  if ($p.Length -gt 1 -and $p.EndsWith("/")) { $p = $p.Substring(0, $p.Length - 1) }
  return $p
}

# ─────────────────────────────────────────────
#  Token store  (DPAPI encrypted, same pattern as Vercel deployer)
# ─────────────────────────────────────────────
function Get-TokenStorePath { return (Join-Path $scriptDir ".fastly-token.dpapi") }

function Save-TokenSecure([string]$Token) {
  $path   = Get-TokenStorePath
  $secure = ConvertTo-SecureString -String $Token -AsPlainText -Force
  $text   = ConvertFrom-SecureString -SecureString $secure
  $utf8   = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $text, $utf8)
}

function Load-TokenSecure {
  $path = Get-TokenStorePath
  if (-not (Test-Path $path)) { return "" }
  try {
    $text   = (Get-Content $path -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $secure = ConvertTo-SecureString -String $text
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  } catch { return "" }
}

# ─────────────────────────────────────────────
#  Project state store
# ─────────────────────────────────────────────
function Get-StateStorePath { return (Join-Path $scriptDir ".fastly-deploy-state.json") }

function Load-DeployState {
  $path = Get-StateStorePath
  if (-not (Test-Path $path)) { return @() }
  try {
    $raw = Get-Content $path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $obj = $raw | ConvertFrom-Json
    if ($null -eq $obj -or $null -eq $obj.services) { return @() }
    return @($obj.services)
  } catch { return @() }
}

function Save-DeployState([array]$Services) {
  $path  = Get-StateStorePath
  $state = [ordered]@{ services = @($Services | Sort-Object Name) }
  $utf8  = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 20), $utf8)
}

function Add-DeployStateEntry([string]$Name, [string]$ServiceId, [string]$Domain,
                               [string]$TargetDomain, [string]$RelayPath,
                               [int]$ConnectTimeout = 10000,
                               [int]$FirstByteTimeout = 300000,
                               [int]$BetweenBytesTimeout = 300000) {
  $services = @(Load-DeployState | Where-Object { [string]$_.Name -ne $Name })
  $services += [pscustomobject]@{
    Name                 = $Name
    ServiceId            = $ServiceId
    Domain               = $Domain
    TargetDomain         = $TargetDomain
    RelayPath            = $RelayPath
    ConnectTimeout       = $ConnectTimeout
    FirstByteTimeout     = $FirstByteTimeout
    BetweenBytesTimeout  = $BetweenBytesTimeout
    DeployedAt           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  }
  Save-DeployState -Services $services
}

# ─────────────────────────────────────────────
#  Fastly API helpers
# ─────────────────────────────────────────────
function Invoke-FastlyApi {
  param(
    [string]$Method = "GET",
    [string]$Path,
    [string]$Token,
    [hashtable]$Body = $null,
    [string]$ContentType = "application/json"
  )
  $uri     = "https://api.fastly.com$Path"
  $headers = @{ "Fastly-Key" = $Token; "Accept" = "application/json" }
  try {
    if ($null -ne $Body) {
      $json = $Body | ConvertTo-Json -Depth 20
      return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers `
             -Body $json -ContentType $ContentType -TimeoutSec 30
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -TimeoutSec 30
  } catch {
    $msg = $_.Exception.Message
    try {
      $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).detail
      if (-not [string]::IsNullOrWhiteSpace($detail)) { $msg = $detail }
    } catch {}
    throw "Fastly API error ($Method $Path): $msg"
  }
}

function Test-FastlyToken([string]$Token) {
  try {
    $r = Invoke-FastlyApi -Method GET -Path "/tokens/self" -Token $Token
    return ($null -ne $r -and -not [string]::IsNullOrWhiteSpace([string]$r.id))
  } catch { return $false }
}

function Get-FastlyServices([string]$Token) {
  try {
    $r = Invoke-FastlyApi -Method GET -Path "/service?per_page=100" -Token $Token
    if ($null -eq $r) { return @() }
    return @($r | Where-Object { [string]$_.type -eq "wasm" })
  } catch { return @() }
}

function New-FastlyService([string]$Token, [string]$Name) {
  $body = @{ name = $Name; type = "wasm" }
  return Invoke-FastlyApi -Method POST -Path "/service" -Token $Token -Body $body
}

function New-FastlyServiceVersion([string]$Token, [string]$ServiceId) {
  return Invoke-FastlyApi -Method POST -Path "/service/$ServiceId/version" -Token $Token
}

function Clone-FastlyVersion([string]$Token, [string]$ServiceId, [int]$Version) {
  return Invoke-FastlyApi -Method PUT -Path "/service/$ServiceId/version/$Version/clone" -Token $Token
}

function Add-FastlyDomain([string]$Token, [string]$ServiceId, [int]$Version, [string]$DomainName) {
  $body = @{ name = $DomainName }
  return Invoke-FastlyApi -Method POST -Path "/service/$ServiceId/version/$Version/domain" `
         -Token $Token -Body $body
}

function Add-FastlyBackend([string]$Token, [string]$ServiceId, [int]$Version,
                            [string]$Hostname, [int]$Port,
                            [int]$ConnectTimeout = 10000,
                            [int]$FirstByteTimeout = 300000,
                            [int]$BetweenBytesTimeout = 300000) {
  $uri     = "https://api.fastly.com/service/$ServiceId/version/$Version/backend"
  $headers = @{ "Fastly-Key" = $Token; "Accept" = "application/json" }
  $form    = "name=origin_xhttp&address=$Hostname&port=$Port&use_ssl=1&ssl_check_cert=1" +
             "&ssl_sni_hostname=$Hostname&ssl_cert_hostname=$Hostname" +
             "&override_host=$Hostname&connect_timeout=$ConnectTimeout" +
             "&first_byte_timeout=$FirstByteTimeout&between_bytes_timeout=$BetweenBytesTimeout"
  return Invoke-RestMethod -Method POST -Uri $uri -Headers $headers `
         -Body $form -ContentType "application/x-www-form-urlencoded" -TimeoutSec 30
}

function Validate-FastlyVersion([string]$Token, [string]$ServiceId, [int]$Version) {
  return Invoke-FastlyApi -Method GET -Path "/service/$ServiceId/version/$Version/validate" -Token $Token
}

function Activate-FastlyVersion([string]$Token, [string]$ServiceId, [int]$Version) {
  return Invoke-FastlyApi -Method PUT -Path "/service/$ServiceId/version/$Version/activate" -Token $Token
}

function Upload-FastlyPackage([string]$Token, [string]$ServiceId, [int]$Version, [string]$PkgPath) {
  $uri      = "https://api.fastly.com/service/$ServiceId/version/$Version/package"
  $boundary = "----FastlyBoundary" + [System.Guid]::NewGuid().ToString("N")
  $pkgBytes = [System.IO.File]::ReadAllBytes($PkgPath)
  $pkgName  = [System.IO.Path]::GetFileName($PkgPath)

  $pre  = [System.Text.Encoding]::UTF8.GetBytes(
    "--$boundary`r`nContent-Disposition: form-data; name=`"package`"; filename=`"$pkgName`"`r`nContent-Type: application/octet-stream`r`n`r`n"
  )
  $post = [System.Text.Encoding]::UTF8.GetBytes("`r`n--$boundary--`r`n")

  $body = New-Object byte[] ($pre.Length + $pkgBytes.Length + $post.Length)
  [System.Buffer]::BlockCopy($pre,      0, $body, 0,                                $pre.Length)
  [System.Buffer]::BlockCopy($pkgBytes, 0, $body, $pre.Length,                      $pkgBytes.Length)
  [System.Buffer]::BlockCopy($post,     0, $body, $pre.Length + $pkgBytes.Length,   $post.Length)

  $headers = @{
    "Fastly-Key"   = $Token
    "Accept"       = "application/json"
    "Content-Type" = "multipart/form-data; boundary=$boundary"
  }
  return Invoke-RestMethod -Method PUT -Uri $uri -Headers $headers -Body $body -TimeoutSec 300
}


# ─────────────────────────────────────────────
#  Config Store helpers (Fastly ENV equivalent)
# ─────────────────────────────────────────────
function New-FastlyConfigStore([string]$Token, [string]$Name) {
  try {
    return Invoke-FastlyApi -Method POST -Path "/resources/stores/config" -Token $Token `
           -Body @{ name = $Name }
  } catch {
    # May already exist - try to find it
    $stores = Get-FastlyConfigStores -Token $Token
    return ($stores | Where-Object { [string]$_.name -eq $Name } | Select-Object -First 1)
  }
}

function Get-FastlyConfigStores([string]$Token) {
  try {
    $r = Invoke-FastlyApi -Method GET -Path "/resources/stores/config" -Token $Token
    if ($null -eq $r) { return @() }
    if ($r.PSObject.Properties.Name -contains "data") { return @($r.data) }
    return @($r)
  } catch { return @() }
}

function Set-FastlyConfigStoreItem([string]$Token, [string]$StoreId, [string]$Key, [string]$Value) {
  $uri     = "https://api.fastly.com/resources/stores/config/$StoreId/item/$Key"
  $headers = @{ "Fastly-Key" = $Token; "Accept" = "application/json"; "Content-Type" = "application/json" }
  $body    = @{ item_value = $Value } | ConvertTo-Json
  try {
    Invoke-RestMethod -Method PUT -Uri $uri -Headers $headers -Body $body -TimeoutSec 15 | Out-Null
  } catch {
    Invoke-RestMethod -Method POST -Uri ($uri -replace "/item/$Key","") -Headers $headers `
      -Body (@{ item_key = $Key; item_value = $Value } | ConvertTo-Json) -TimeoutSec 15 | Out-Null
  }
}

function Link-ConfigStoreToService([string]$Token, [string]$ServiceId, [int]$Version, [string]$StoreId) {
  $uri     = "https://api.fastly.com/service/$ServiceId/version/$Version/resource"
  $headers = @{ "Fastly-Key" = $Token; "Accept" = "application/json" }
  $form    = "resource_id=$StoreId&name=relay_config"
  try {
    Invoke-RestMethod -Method POST -Uri $uri -Headers $headers `
      -Body $form -ContentType "application/x-www-form-urlencoded" -TimeoutSec 15 | Out-Null
  } catch {
    Write-Warn "Config Store link note: $($_.Exception.Message)"
  }
}

function Push-ConfigStore([string]$Token, [string]$ServiceId, [int]$Version, [hashtable]$cfg) {
  Write-Step "Creating Config Store (relay ENV variables)..."
  $storeName = "relay_config_$($cfg.ServiceName)"
  $store     = New-FastlyConfigStore -Token $Token -Name $storeName
  if ($null -eq $store -or [string]::IsNullOrWhiteSpace([string]$store.id)) {
    Write-Warn "Could not create Config Store - values will use fallback defaults."
    return
  }
  $storeId = [string]$store.id
  Write-OK "Config Store: $storeName ($storeId)"

  Set-FastlyConfigStoreItem -Token $Token -StoreId $storeId -Key "TARGET_BASE"     -Value $cfg.TargetDomain
  Set-FastlyConfigStoreItem -Token $Token -StoreId $storeId -Key "TARGET_HOSTNAME" -Value $cfg.Hostname
  Set-FastlyConfigStoreItem -Token $Token -StoreId $storeId -Key "RELAY_PATH"      -Value $cfg.RelayPath
  Write-OK "Config Store values set: TARGET_BASE, TARGET_HOSTNAME, RELAY_PATH"

  Link-ConfigStoreToService -Token $Token -ServiceId $ServiceId -Version $Version -StoreId $storeId
  Write-OK "Config Store linked to service version $Version."
}
function Get-FastlyActiveVersion([string]$Token, [string]$ServiceId) {
  try {
    $r = Invoke-FastlyApi -Method GET -Path "/service/$ServiceId/details" -Token $Token
    return [int]$r.active_version.number
  } catch { return 0 }
}

# ─────────────────────────────────────────────
#  Node / npm / js-compute-runtime helpers
# ─────────────────────────────────────────────
function Refresh-Path {
  $machine  = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $user     = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machine;$user"
}

function Ensure-Node {
  if (Get-Command $NpmExe -ErrorAction SilentlyContinue) {
    Write-OK "npm already installed."
    return
  }
  if ($SkipNodeInstall) { throw "npm is missing and -SkipNodeInstall was used." }
  if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
    throw "winget not found. Install Node.js LTS manually and retry."
  }
  Write-Step "Installing Node.js LTS via winget..."
  winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
  Refresh-Path
  if (-not (Get-Command $NpmExe -ErrorAction SilentlyContinue)) {
    throw "Node.js installed but npm not detected. Re-open PowerShell and retry."
  }
}

function Ensure-JsComputeRuntime {
  Write-Step "Checking @fastly/js-compute..."
  Set-Location $scriptDir
  if (-not (Test-Path (Join-Path $scriptDir "node_modules\.bin\js-compute-runtime.cmd")) -and
      -not (Test-Path (Join-Path $scriptDir "node_modules\.bin\js-compute-runtime"))) {
    Write-Warn "js-compute-runtime not found. Running npm install..."
    & $NpmExe install | Out-Host
  } else {
    Write-OK "js-compute-runtime found."
  }
}

# ─────────────────────────────────────────────
#  Source code writer
# ─────────────────────────────────────────────
function Write-IndexJs([string]$TargetBase, [string]$TargetHostname, [string]$RelayPath) {
  # index.js reads config from Fastly Config Store at runtime
  # The source file is already correctly set up - no changes needed here
  # Config Store values are pushed separately via the API after deploy
  Write-OK "Source file uses Config Store - no static rewrite needed."
}

# ─────────────────────────────────────────────
#  Build
# ─────────────────────────────────────────────
function Invoke-Build {
  Write-Step "Building Wasm package..."
  Set-Location $scriptDir
  $npmPath = (Get-Command $NpmExe -ErrorAction Stop).Source
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName         = $npmPath
  $psi.Arguments        = "run build"
  $psi.WorkingDirectory = $scriptDir
  $psi.UseShellExecute  = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  $proc.WaitForExit(300000) | Out-Null
  $proc.WaitForExit()

  $stdout = $outTask.GetAwaiter().GetResult()
  $stderr = $errTask.GetAwaiter().GetResult()

  foreach ($line in ($stdout -split "`r?`n" | Where-Object { $_ -ne "" })) {
    Write-Host "   $line" -ForegroundColor DarkGray
  }
  foreach ($line in ($stderr -split "`r?`n" | Where-Object { $_ -ne "" })) {
    if ($line -match "error|Error|fail|Fail") {
      Write-Err $line
    } else {
      Write-Host "   $line" -ForegroundColor DarkGray
    }
  }

  if ($proc.ExitCode -ne 0) { throw "Build failed (exit $($proc.ExitCode))." }
  Write-OK "Build succeeded."
}

# ─────────────────────────────────────────────
#  Package tar.gz builder
# ─────────────────────────────────────────────
function Build-Package([string]$ServiceName) {
  Write-Step "Packaging Wasm..."
  $pkgDir  = Join-Path $scriptDir "pkg"
  if (-not (Test-Path $pkgDir)) { New-Item -ItemType Directory -Path $pkgDir | Out-Null }

  $tmpDir  = Join-Path $pkgDir $ServiceName
  if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir }
  New-Item -ItemType Directory -Path (Join-Path $tmpDir "bin") | Out-Null

  Copy-Item (Join-Path $scriptDir "bin\main.wasm")  (Join-Path $tmpDir "bin\main.wasm")
  Copy-Item (Join-Path $scriptDir "fastly.toml")    (Join-Path $tmpDir "fastly.toml")

  $stamp  = Get-Date -Format "yyyyMMddHHmmss"
  $outTar = Join-Path $pkgDir "deploy_$stamp.tar.gz"

  Push-Location $pkgDir
  try { tar -czf "deploy_$stamp.tar.gz" $ServiceName }
  finally { Pop-Location }

  Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
  Write-OK "Package: $outTar"
  return $outTar
}

# ─────────────────────────────────────────────
#  fastly.toml updater
# ─────────────────────────────────────────────
function Update-FastlyToml([string]$ServiceName) {
  $tomlPath = Join-Path $scriptDir "fastly.toml"
  $content  = @"
manifest_version = 3
name             = "$ServiceName"
description      = "XHTTPRelayECO Fastly Compute relay"
authors          = ["Behnam"]
language         = "javascript"

[scripts]
build = "npm run build"
"@
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($tomlPath, $content, $utf8)
}

# ─────────────────────────────────────────────
#  Health check
# ─────────────────────────────────────────────
function Run-HealthCheck([string]$Domain, [string]$RelayPath) {
  Write-Step "Running health check..."
  $url = "https://$Domain$RelayPath/healthcheck-probe"
  try {
    # Use curl.exe for reliable status code detection (avoids PowerShell exception on 4xx/5xx)
    $code = & curl.exe -s -o NUL -w "%{http_code}" --max-time 15 $url 2>$null
    $code = ([string]$code).Trim()
    if ($code -eq "400" -or $code -eq "404") {
      Write-OK "Relay is working. Origin responded with HTTP $code (expected for xhttp)."
    } elseif ($code -eq "200") {
      Write-OK "Relay is working. HTTP 200 OK."
    } elseif ($code -eq "000" -or [string]::IsNullOrWhiteSpace($code)) {
      Write-Warn "Could not reach endpoint - DNS may still be propagating. Try again in 1-2 minutes."
    } elseif ($code -eq "500") {
      Write-Warn "HTTP 500 - Config Store may not be linked yet. Try redeploying in 30 seconds."
    } elseif ($code -eq "502") {
      Write-Warn "HTTP 502 - Backend unreachable. Check origin server and port."
    } else {
      Write-Warn "HTTP $code - Unexpected response. Check origin server."
    }
  } catch {
    Write-Warn "Health check skipped: $($_.Exception.Message)"
  }
}

# ─────────────────────────────────────────────
#  Config summary printer
# ─────────────────────────────────────────────
function Show-FinalSummary([hashtable]$cfg, [string]$Domain, [string]$ServiceId, [int]$Version) {
  Write-Host ""
  Write-Host "==============================================" -ForegroundColor Green
  Write-Host " Deployment Complete!" -ForegroundColor Green
  Write-Host "==============================================" -ForegroundColor Green
  Write-Host ""
  Write-Info "Service Name          : $($cfg.ServiceName)"
  Write-Info "Service ID            : $ServiceId"
  Write-Info "Version               : $Version"
  Write-Info "Domain                : $Domain"
  Write-Info "Target                : $($cfg.TargetDomain)"
  Write-Info "Relay Path            : $($cfg.RelayPath)"
  Write-Info "connect_timeout       : $($cfg.ConnectTimeout)ms"
  Write-Info "first_byte_timeout    : $($cfg.FirstByteTimeout)ms"
  Write-Info "between_bytes_timeout : $($cfg.BetweenBytesTimeout)ms"
  Write-Host ""
  Write-Host " Client config:" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "  Do you want to enter your VLESS UUID for a ready-to-use config?" -ForegroundColor Cyan
  Write-Host "  (Press Enter to skip and get a sample config instead)" -ForegroundColor DarkGray
  $uuidInput = Read-Host "  VLESS UUID"
  $uuidInput = $uuidInput.Trim().Trim('"').Trim("'")

  $vlessBase = "vless://{0}@${Domain}:443?encryption=none&security=tls&sni=$Domain&fp=chrome&insecure=0&type=xhttp&host=$Domain&path=$([uri]::EscapeDataString($cfg.RelayPath))&mode=auto#XHTTP-Fastly-Compute"

  Write-Host ""
  if (-not [string]::IsNullOrWhiteSpace($uuidInput)) {
    $vlessUrl = $vlessBase -f $uuidInput
    Write-Host "  Ready-to-use config:" -ForegroundColor Green
    Write-Host ""
    Write-Host "  $vlessUrl" -ForegroundColor Cyan
  } else {
    $vlessUrl = $vlessBase -f "YOUR-UUID-HERE"
    Write-Host "  Sample config (replace YOUR-UUID-HERE with your VLESS UUID):" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  $vlessUrl" -ForegroundColor Cyan
  }
  Write-Host ""
  Write-Host "==============================================" -ForegroundColor Green

  # Save build profile
  $stamp     = Get-Date -Format "yyyyMMdd-HHmmss"
  $profPath  = Join-Path $scriptDir "build-profile-fastly-$stamp.txt"
  $lines     = @(
    "XHTTPRelayECO Fastly Compute Build Profile",
    "generated_at=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "service_name=$($cfg.ServiceName)",
    "service_id=$ServiceId",
    "active_version=$Version",
    "domain=$Domain",
    "target_domain=$($cfg.TargetDomain)",
    "relay_path=$($cfg.RelayPath)",
    "runtime=fastly-compute-javascript"
  )
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($profPath, $lines, $utf8)
  Write-OK "Build profile saved: build-profile-fastly-$stamp.txt"
}

# ─────────────────────────────────────────────
#  Parse target domain into hostname + port + base
# ─────────────────────────────────────────────
function Parse-TargetDomain([string]$Raw) {
  $raw = $Raw.Trim().TrimEnd("/")
  if (-not ($raw -match '^[a-zA-Z]+://')) { $raw = "https://$raw" }
  try {
    $u        = [uri]$raw
    $hostname = $u.Host
    $port     = if ($u.Port -gt 0) { $u.Port } else { 443 }
    $base     = "$($u.Scheme)://$($u.Host):$port"
    return @{ Hostname = $hostname; Port = $port; Base = $base; Valid = $true }
  } catch {
    return @{ Valid = $false }
  }
}

# ─────────────────────────────────────────────
#  Service selector
# ─────────────────────────────────────────────
function Select-ExistingService([string]$Token) {
  Write-Step "Fetching your Fastly Compute services..."
  $services = Get-FastlyServices -Token $Token
  if ($services.Count -eq 0) {
    Write-Warn "No existing Compute services found."
    return $null
  }
  Write-Host ""
  Write-Host "  Existing Compute services:" -ForegroundColor Cyan
  for ($i = 0; $i -lt $services.Count; $i++) {
    $s   = $services[$i]
    $ver = if ($s.active_version) { "v$($s.active_version)" } else { "no active version" }
    Write-Host ("  [{0}] {1}  ({2})  [{3}]" -f ($i + 1), $s.name, $s.id, $ver)
  }
  Write-Host "  [0] Create new service"
  Write-Host ""
  $pick = Read-Default "Select service" "0"
  $n    = 0
  if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $services.Count) {
    return $services[$n - 1]
  }
  return $null
}

# ─────────────────────────────────────────────
#  New deployment flow
# ─────────────────────────────────────────────
function Run-NewDeployFlow([string]$Token) {
  Write-Step "New deployment - collecting config..."

  # Service name
  $suggestedName = "relay-" + (-join (1..8 | ForEach-Object { "abcdefghijklmnopqrstuvwxyz0123456789"[(Get-Random -Minimum 0 -Maximum 36)] }))
  $serviceName   = Read-Default "Service name" $suggestedName

  # Target domain
  Write-Host ""
  Write-Warn "TARGET_DOMAIN: full URL of your inbound server including port."
  Write-Warn "Example: https://your-domain.com:2053"
  $targetRaw = Read-Required "TARGET_DOMAIN"
  $parsed    = Parse-TargetDomain -Raw $targetRaw
  if (-not $parsed.Valid) { throw "Invalid TARGET_DOMAIN format. Use https://hostname:port" }

  # Relay path
  Write-Host ""
  Write-Warn "RELAY_PATH: the path configured on your inbound (e.g. /api)."
  Write-Warn "PUBLIC_RELAY_PATH will be set to the same value automatically."
  $relayPathRaw = Read-Default "RELAY_PATH" "/api"
  $relayPath    = Normalize-Path -p $relayPathRaw

  # Backend timeouts
  Write-Host ""
  Write-Host "  Backend timeout settings:" -ForegroundColor Cyan
  Write-Host ""
  Write-Warn "  connect_timeout: Max time (ms) to establish TCP connection to your origin server."
  Write-Warn "  Default 10000ms (10s). If origin is slow to accept connections, increase this."
  $connectTimeout = [int](Read-Default "  connect_timeout (ms)" "10000")

  Write-Host ""
  Write-Warn "  first_byte_timeout: Max time (ms) to wait for the FIRST byte from origin after"
  Write-Warn "  sending the request. Critical for xhttp - origin may take time to respond."
  Write-Warn "  Default 300000ms (5min). Increase if you see 503/504 errors on slow connections."
  $firstByteTimeout = [int](Read-Default "  first_byte_timeout (ms)" "300000")

  Write-Host ""
  Write-Warn "  between_bytes_timeout: Max time (ms) to wait BETWEEN each chunk of data from origin."
  Write-Warn "  Critical for xhttp streaming - keep high to avoid mid-stream disconnects."
  Write-Warn "  Default 300000ms (5min). Lower this only if you want faster failure detection."
  $betweenBytesTimeout = [int](Read-Default "  between_bytes_timeout (ms)" "300000")

  # Summary
  Write-Host ""
  Write-Host "  Configuration summary:" -ForegroundColor Cyan
  Write-Info "  Service name          : $serviceName"
  Write-Info "  Target domain         : $($parsed.Base)"
  Write-Info "  Relay path            : $relayPath"
  Write-Info "  connect_timeout       : ${connectTimeout}ms"
  Write-Info "  first_byte_timeout    : ${firstByteTimeout}ms"
  Write-Info "  between_bytes_timeout : ${betweenBytesTimeout}ms"
  Write-Host ""
  $ok = Read-YesNo "Proceed with this configuration?" $true
  if (-not $ok) {
    Write-Warn "Canceled. Returning to menu."
    return
  }

  return @{
    ServiceName          = $serviceName
    TargetDomain         = $parsed.Base
    Hostname             = $parsed.Hostname
    Port                 = $parsed.Port
    RelayPath            = $relayPath
    ConnectTimeout       = $connectTimeout
    FirstByteTimeout     = $firstByteTimeout
    BetweenBytesTimeout  = $betweenBytesTimeout
    IsNew                = $true
  }
}

# ─────────────────────────────────────────────
#  Redeploy existing service flow
# ─────────────────────────────────────────────
function Run-RedeployFlow([string]$Token) {
  $svc = Select-ExistingService -Token $Token
  if ($null -eq $svc) {
    # User chose "create new"
    return Run-NewDeployFlow -Token $Token
  }

  Write-Step "Redeploying: $($svc.name)"

  # Try to load saved state
  $saved       = Load-DeployState | Where-Object { [string]$_.ServiceId -eq [string]$svc.id } | Select-Object -First 1
  $defTarget   = if ($null -ne $saved) { [string]$saved.TargetDomain } else { "" }
  $defPath     = if ($null -ne $saved) { [string]$saved.RelayPath }    else { "/api" }

  if (-not [string]::IsNullOrWhiteSpace($defTarget)) {
    Write-Info "Last known target : $defTarget"
    Write-Info "Last known path   : $defPath"
    $keep = Read-YesNo "Keep these values?" $true
    if (-not $keep) { $defTarget = ""; $defPath = "/api" }
  }

  $targetRaw = if ([string]::IsNullOrWhiteSpace($defTarget)) {
    Read-Required "TARGET_DOMAIN (https://hostname:port)"
  } else { $defTarget }

  $parsed = Parse-TargetDomain -Raw $targetRaw
  if (-not $parsed.Valid) { throw "Invalid TARGET_DOMAIN." }

  $relayPathRaw = Read-Default "RELAY_PATH" $defPath
  $relayPath    = Normalize-Path -p $relayPathRaw

  # Timeouts - use saved or defaults
  $defConnect      = if ($null -ne $saved -and $saved.PSObject.Properties.Name -contains "ConnectTimeout")      { [int]$saved.ConnectTimeout }      else { 10000 }
  $defFirstByte    = if ($null -ne $saved -and $saved.PSObject.Properties.Name -contains "FirstByteTimeout")    { [int]$saved.FirstByteTimeout }    else { 300000 }
  $defBetweenBytes = if ($null -ne $saved -and $saved.PSObject.Properties.Name -contains "BetweenBytesTimeout") { [int]$saved.BetweenBytesTimeout } else { 300000 }

  $changeTimeouts = Read-YesNo "Change backend timeout settings? (current: connect=${defConnect}ms, first_byte=${defFirstByte}ms, between=${defBetweenBytes}ms)" $false
  if ($changeTimeouts) {
    $defConnect      = [int](Read-Default "  connect_timeout (ms)" "$defConnect")
    $defFirstByte    = [int](Read-Default "  first_byte_timeout (ms)" "$defFirstByte")
    $defBetweenBytes = [int](Read-Default "  between_bytes_timeout (ms)" "$defBetweenBytes")
  }

  return @{
    ServiceName          = [string]$svc.name
    ServiceId            = [string]$svc.id
    TargetDomain         = $parsed.Base
    Hostname             = $parsed.Hostname
    Port                 = $parsed.Port
    RelayPath            = $relayPath
    ConnectTimeout       = $defConnect
    FirstByteTimeout     = $defFirstByte
    BetweenBytesTimeout  = $defBetweenBytes
    IsNew                = $false
  }
}

# ─────────────────────────────────────────────
#  Core deploy pipeline
# ─────────────────────────────────────────────
function Deploy-ToFastly([hashtable]$cfg, [string]$Token) {

  # 1. Update source files
  Write-Step "Writing relay source..."
  Update-FastlyToml  -ServiceName $cfg.ServiceName
  Write-IndexJs      -TargetBase $cfg.TargetDomain -TargetHostname $cfg.Hostname -RelayPath $cfg.RelayPath
  Write-OK "Source files updated."

  # 2. Build
  Ensure-JsComputeRuntime
  Invoke-Build

  # 3. Create or resolve service
  $serviceId = ""
  if ($cfg.IsNew) {
    Write-Step "Creating Fastly Compute service '$($cfg.ServiceName)'..."
    $newSvc    = New-FastlyService -Token $Token -Name $cfg.ServiceName
    $serviceId = [string]$newSvc.id
    Write-OK "Service created: $serviceId"
  } else {
    $serviceId = $cfg.ServiceId
    Write-OK "Using existing service: $serviceId"
  }

  # 4. Create new version
  Write-Step "Creating new service version..."
  $newVer    = New-FastlyServiceVersion -Token $Token -ServiceId $serviceId
  $versionNo = [int]$newVer.number
  Write-OK "Version $versionNo created."

  # 5. Add domain
  Write-Step "Adding Fastly domain..."
  $domain = ""
  try {
    $domResult = Add-FastlyDomain -Token $Token -ServiceId $serviceId -Version $versionNo `
                                  -DomainName "$($cfg.ServiceName).edgecompute.app"
    $domain = [string]$domResult.name
  } catch {
    # Domain may already exist on an existing service - fetch it
    try {
      $existing = Invoke-FastlyApi -Method GET `
                  -Path "/service/$serviceId/version/$versionNo/domain" -Token $Token
      if ($null -ne $existing -and $existing.Count -gt 0) {
        $domain = [string]$existing[0].name
      }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($domain)) {
      $domain = "$($cfg.ServiceName).edgecompute.app"
    }
  }
  Write-OK "Domain: $domain"

  # 5b. Push Config Store (ENV variables)
  Push-ConfigStore -Token $Token -ServiceId $serviceId -Version $versionNo -cfg $cfg

  # 6. Add backend
  Write-Step "Adding backend ($($cfg.Hostname):$($cfg.Port))..."
  try {
    Add-FastlyBackend -Token $Token -ServiceId $serviceId -Version $versionNo `
                      -Hostname $cfg.Hostname -Port $cfg.Port `
                      -ConnectTimeout $cfg.ConnectTimeout `
                      -FirstByteTimeout $cfg.FirstByteTimeout `
                      -BetweenBytesTimeout $cfg.BetweenBytesTimeout | Out-Null
    Write-OK "Backend added."
  } catch {
    Write-Warn "Backend note: $($_.Exception.Message)"
  }

  # 7. Package
  $pkgPath = Build-Package -ServiceName $cfg.ServiceName

  # 8. Upload package
  Write-Step "Uploading Wasm package to Fastly..."
  try {
    Upload-FastlyPackage -Token $Token -ServiceId $serviceId -Version $versionNo `
                         -PkgPath $pkgPath | Out-Null
    Write-OK "Package uploaded."
  } catch {
    throw "Package upload failed: $($_.Exception.Message)"
  }

  # 9. Validate
  Write-Step "Validating version $versionNo..."
  try {
    $validation = Validate-FastlyVersion -Token $Token -ServiceId $serviceId -Version $versionNo
    if ([string]$validation.status -eq "ok") {
      Write-OK "Validation passed."
    } else {
      $errs = ($validation.errors -join "; ")
      throw "Validation failed: $errs"
    }
  } catch {
    throw "Validation error: $($_.Exception.Message)"
  }

  # 10. Activate
  Write-Step "Activating version $versionNo..."
  Activate-FastlyVersion -Token $Token -ServiceId $serviceId -Version $versionNo | Out-Null
  Write-OK "Version $versionNo is now active."

  # 11. Save state
  Add-DeployStateEntry -Name $cfg.ServiceName -ServiceId $serviceId -Domain $domain `
                       -TargetDomain $cfg.TargetDomain -RelayPath $cfg.RelayPath `
                       -ConnectTimeout $cfg.ConnectTimeout -FirstByteTimeout $cfg.FirstByteTimeout `
                       -BetweenBytesTimeout $cfg.BetweenBytesTimeout

  # 12. Health check + summary
  Write-Host ""
  Write-Warn "Waiting 25 seconds for CDN propagation..."
  Start-Sleep -Seconds 25
  Run-HealthCheck -Domain $domain -RelayPath $cfg.RelayPath
  Show-FinalSummary -cfg $cfg -Domain $domain -ServiceId $serviceId -Version $versionNo
}

# ─────────────────────────────────────────────
#  Auth flow
# ─────────────────────────────────────────────
function Ensure-FastlyToken {
  Write-Step "Fastly API token..."

  $saved = Load-TokenSecure
  if (-not [string]::IsNullOrWhiteSpace($saved)) {
    Write-Info "Saved encrypted token found."
    $use = Read-YesNo "Use saved token?" $true
    if ($use) {
      if (Test-FastlyToken -Token $saved) {
        Write-OK "Token validated."
        return $saved
      }
      Write-Warn "Saved token is invalid. Please enter a new one."
    }
  }

  Write-Host ""
  Write-Warn "Create a token at: https://manage.fastly.com/account/personal/tokens"
  Write-Warn "Required scope: global (or at minimum: purge_all, engineer)"
  Write-Host ""
  $token = Read-Required "Paste your Fastly API token"
  $token = $token.Trim().Trim('"').Trim("'")

  Write-Step "Validating token..."
  if (-not (Test-FastlyToken -Token $token)) {
    throw "Token validation failed. Check the token and try again."
  }
  Write-OK "Token is valid."

  $save = Read-YesNo "Save token encrypted on this machine?" $true
  if ($save) {
    Save-TokenSecure -Token $token
    Write-OK "Token saved: $(Get-TokenStorePath)"
  }

  return $token
}


# ─────────────────────────────────────────────
#  Manage Services helpers
# ─────────────────────────────────────────────
function Get-ServiceConfigStoreSummary([string]$Token, [string]$ServiceId, [int]$Version) {
  try {
    $resources = Invoke-FastlyApi -Method GET `
      -Path "/service/$ServiceId/version/$Version/resource" -Token $Token
    if ($null -eq $resources -or $resources.Count -eq 0) { return $null }
    $link = @($resources | Where-Object { [string]$_.name -eq "relay_config" }) | Select-Object -First 1
    if ($null -eq $link) { return $null }
    $storeId = [string]$link.resource_id
    $items = Invoke-FastlyApi -Method GET `
      -Path "/resources/stores/config/$storeId/items" -Token $Token
    if ($null -eq $items) { return $null }
    $result = @{ StoreId = $storeId; Items = @{} }
    foreach ($item in $items) {
      $result.Items[[string]$item.item_key] = [string]$item.item_value
    }
    return $result
  } catch { return $null }
}

function Get-ServiceBackendSummary([string]$Token, [string]$ServiceId, [int]$Version) {
  try {
    $backends = Invoke-FastlyApi -Method GET `
      -Path "/service/$ServiceId/version/$Version/backend" -Token $Token
    if ($null -eq $backends -or $backends.Count -eq 0) { return $null }
    return $backends[0]
  } catch { return $null }
}

function Select-ServiceFromFastly([string]$Token) {
  Write-Step "Fetching Compute services from Fastly..."
  $services = Get-FastlyServices -Token $Token
  if ($services.Count -eq 0) {
    Write-Warn "No Compute services found on this account."
    return $null
  }
  Write-Host ""
  Write-Host "  Your Fastly Compute services:" -ForegroundColor Cyan
  Write-Host ""
  for ($i = 0; $i -lt $services.Count; $i++) {
    $s   = $services[$i]
    $ver = if ($s.active_version) { "v$($s.active_version)" } else { "no active version" }
    Write-Host ("  [{0}] {1}" -f ($i + 1), $s.name) -ForegroundColor White
    Write-Host ("       ID: {0}  |  {1}" -f $s.id, $ver) -ForegroundColor DarkGray
  }
  Write-Host ""
  Write-Host "  [0] Back"
  Write-Host ""
  $pick = Read-Default "Select service" "0"
  $n = 0
  if ([int]::TryParse($pick.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $services.Count) {
    return $services[$n - 1]
  }
  return $null
}

function Show-ServiceConfigSummary([string]$Token, $Svc) {
  $serviceId = [string]$Svc.id
  $version   = if ($Svc.active_version) { [int]$Svc.active_version } else { 0 }
  if ($version -eq 0) { Write-Warn "No active version found."; return }

  Write-Host ""
  Write-Host "  ============================================" -ForegroundColor Cyan
  Write-Host "  Service: $($Svc.name)" -ForegroundColor White
  Write-Host "  ============================================" -ForegroundColor Cyan
  Write-Info "  Service ID  : $serviceId"
  Write-Info "  Domain      : $($Svc.name).edgecompute.app"
  Write-Info "  Version     : $version"

  $cfg = Get-ServiceConfigStoreSummary -Token $Token -ServiceId $serviceId -Version $version
  if ($null -ne $cfg) {
    Write-Host ""
    Write-Host "  Config Store (ENV):" -ForegroundColor Yellow
    Write-Info "  TARGET_BASE     : $($cfg.Items['TARGET_BASE'])"
    Write-Info "  TARGET_HOSTNAME : $($cfg.Items['TARGET_HOSTNAME'])"
    Write-Info "  RELAY_PATH      : $($cfg.Items['RELAY_PATH'])"
  } else {
    Write-Warn "  No Config Store linked."
  }

  $backend = Get-ServiceBackendSummary -Token $Token -ServiceId $serviceId -Version $version
  if ($null -ne $backend) {
    Write-Host ""
    Write-Host "  Backend timeouts:" -ForegroundColor Yellow
    Write-Info "  connect_timeout       : $($backend.connect_timeout)ms"
    Write-Info "  first_byte_timeout    : $($backend.first_byte_timeout)ms"
    Write-Info "  between_bytes_timeout : $($backend.between_bytes_timeout)ms"
  }

  Write-Host "  ============================================" -ForegroundColor Cyan
}

function Edit-ServiceConfigStore([string]$Token, $Svc) {
  $serviceId = [string]$Svc.id
  $version   = if ($Svc.active_version) { [int]$Svc.active_version } else { 0 }
  if ($version -eq 0) { Write-Warn "No active version found."; return }

  $cfg = Get-ServiceConfigStoreSummary -Token $Token -ServiceId $serviceId -Version $version
  if ($null -eq $cfg) {
    Write-Warn "No Config Store linked to this service."
    return
  }

  $storeId = $cfg.StoreId
  Write-Host ""
  Write-Host "  Edit Config Store for: $($Svc.name)" -ForegroundColor Cyan
  Write-Host "  (Press Enter to keep current value)" -ForegroundColor DarkGray
  Write-Host ""

  $fields = @(
    @{ Key = "TARGET_BASE";     Label = "TARGET_BASE     (e.g. https://domain.com:2053)";  Current = $cfg.Items['TARGET_BASE'] },
    @{ Key = "TARGET_HOSTNAME"; Label = "TARGET_HOSTNAME (e.g. domain.com)";               Current = $cfg.Items['TARGET_HOSTNAME'] },
    @{ Key = "RELAY_PATH";      Label = "RELAY_PATH      (e.g. /api)";                     Current = $cfg.Items['RELAY_PATH'] }
  )

  $changes = @{}
  foreach ($f in $fields) {
    Write-Info "  Current $($f.Key): $($f.Current)"
    $raw = Read-Host "  New value for $($f.Label)"
    $raw = $raw.Trim()
    if (-not [string]::IsNullOrWhiteSpace($raw) -and $raw -ne $f.Current) {
      $changes[$f.Key] = $raw
    }
  }

  if ($changes.Count -eq 0) {
    Write-Warn "No changes made."
    return
  }

  Write-Host ""
  Write-Host "  Pending changes:" -ForegroundColor Yellow
  foreach ($k in $changes.Keys) {
    Write-Info "  $k = $($changes[$k])"
  }
  Write-Host ""
  $ok = Read-YesNo "Apply changes now? (no redeploy needed)" $true
  if (-not $ok) { Write-Warn "Canceled."; return }

  foreach ($k in $changes.Keys) {
    $uri     = "https://api.fastly.com/resources/stores/config/$storeId/item/$k"
    $headers = @{ "Fastly-Key" = $Token; "Content-Type" = "application/json" }
    $body    = @{ item_value = $changes[$k] } | ConvertTo-Json
    try {
      Invoke-RestMethod -Method PUT -Uri $uri -Headers $headers -Body $body -TimeoutSec 15 | Out-Null
      Write-OK "Updated: $k"
    } catch {
      Write-Warn "Failed to update $k`: $($_.Exception.Message)"
    }
  }
  Write-OK "Config Store updated. Changes are live immediately - no redeploy needed."
}

function Remove-FastlyService([string]$Token, $Svc) {
  $serviceId = [string]$Svc.id
  Write-Host ""
  Write-Host "  Service to delete: $($Svc.name)" -ForegroundColor Red
  Write-Host "  Service ID       : $serviceId" -ForegroundColor Red
  Write-Host ""
  $confirm = Read-YesNo "Are you sure you want to DELETE this service? This cannot be undone." $false
  if (-not $confirm) { Write-Warn "Canceled."; return }

  # Deactivate first
  try {
    $version = if ($Svc.active_version) { [int]$Svc.active_version } else { 0 }
    if ($version -gt 0) {
      Invoke-FastlyApi -Method PUT `
        -Path "/service/$serviceId/version/$version/deactivate" -Token $Token | Out-Null
      Write-OK "Version $version deactivated."
    }
  } catch { Write-Warn "Could not deactivate version: $($_.Exception.Message)" }

  # Delete service
  try {
    Invoke-FastlyApi -Method DELETE -Path "/service/$serviceId" -Token $Token | Out-Null
    Write-OK "Service '$($Svc.name)' deleted."

    # Remove from local state
    $services = @(Load-DeployState | Where-Object { [string]$_.ServiceId -ne $serviceId })
    Save-DeployState -Services $services
  } catch {
    Write-Err "Delete failed: $($_.Exception.Message)"
  }
}

function Show-ManageServicesMenu([string]$Token) {
  while ($true) {
    Write-Banner
    Write-Host "  Manage Services" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] List all services        - show all Compute services on your account" -ForegroundColor Green
    Write-Host "  [2] View service details      - config, ENV, timeouts for a service" -ForegroundColor Green
    Write-Host "  [3] Edit ENV (Config Store)   - change TARGET, PATH without redeploy" -ForegroundColor Yellow
    Write-Host "  [4] Delete service            - permanently remove a service" -ForegroundColor Red
    Write-Host "  [0] Back to main menu"
    Write-Host ""

    $pick = Read-Default "Select" "0"
    switch ($pick.Trim()) {

      "1" {
        Write-Step "All Compute services on your account:"
        $services = Get-FastlyServices -Token $Token
        if ($services.Count -eq 0) {
          Write-Warn "No Compute services found."
        } else {
          Write-Host ""
          foreach ($s in $services) {
            $ver = if ($s.active_version) { "v$($s.active_version)" } else { "no active version" }
            Write-Host ("  {0}" -f $s.name) -ForegroundColor White
            Write-Host ("  ID: {0}  |  {1}  |  {2}.edgecompute.app" -f $s.id, $ver, $s.name) -ForegroundColor DarkGray
            Write-Host ""
          }
        }
        Read-Host "Press Enter to continue"
      }

      "2" {
        $svc = Select-ServiceFromFastly -Token $Token
        if ($null -ne $svc) {
          Show-ServiceConfigSummary -Token $Token -Svc $svc
          Read-Host "`nPress Enter to continue"
        }
      }

      "3" {
        $svc = Select-ServiceFromFastly -Token $Token
        if ($null -ne $svc) {
          Edit-ServiceConfigStore -Token $Token -Svc $svc
          Read-Host "`nPress Enter to continue"
        }
      }

      "4" {
        $svc = Select-ServiceFromFastly -Token $Token
        if ($null -ne $svc) {
          Remove-FastlyService -Token $Token -Svc $svc
          Read-Host "`nPress Enter to continue"
        }
      }

      "0" { return }
      default { Write-Warn "Invalid selection." }
    }
  }
}
# ─────────────────────────────────────────────
#  Main menu
# ─────────────────────────────────────────────
function Show-MainMenu([string]$Token) {
  while ($true) {
    Write-Banner
    Write-Host "  Main Menu" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] New deployment        - create a new Fastly Compute service" -ForegroundColor Green
    Write-Host "  [2] Redeploy / update     - push new build to an existing service" -ForegroundColor Green
    Write-Host "  [3] Manage services       - list, view, edit ENV, delete services" -ForegroundColor Cyan
    Write-Host "  [4] Change API token      - replace the saved Fastly token" -ForegroundColor DarkYellow
    Write-Host "  [0] Exit"
    Write-Host ""

    $pick = Read-Default "Select" "1"
    switch ($pick.Trim()) {

      "1" {
        $cfg = Run-NewDeployFlow -Token $Token
        if ($null -ne $cfg) {
          Deploy-ToFastly -cfg $cfg -Token $Token
          Read-Host "`nPress Enter to return to menu"
        }
      }

      "2" {
        $cfg = Run-RedeployFlow -Token $Token
        if ($null -ne $cfg) {
          Deploy-ToFastly -cfg $cfg -Token $Token
          Read-Host "`nPress Enter to return to menu"
        }
      }

      "3" {
        Show-ManageServicesMenu -Token $Token
      }

      "4" {
        $tokenPath = Get-TokenStorePath
        if (Test-Path $tokenPath) { Remove-Item -Force $tokenPath }
        $Token = Ensure-FastlyToken
        Read-Host "`nToken updated. Press Enter to continue"
      }

      "0" { Write-Host "Goodbye!" -ForegroundColor Cyan; return }

      default { Write-Warn "Invalid selection." }
    }
  }
}

# ─────────────────────────────────────────────
#  Entry point
# ─────────────────────────────────────────────
Write-Banner
Write-Host "  Important: connect VPN (TUN mode) before continuing." -ForegroundColor Magenta
Write-Host "  Tip: Ctrl+C to exit at any time." -ForegroundColor DarkYellow
Write-Host ""

try {
  Ensure-Node
  $token = Ensure-FastlyToken
  Show-MainMenu -Token $token
} catch {
  Write-Host ""
  Write-Err "Fatal error: $($_.Exception.Message)"
  Write-Host ""
  Read-Host "Press Enter to exit"
  exit 1
}
