<div align="center">

# ⚡ XHTTP Relay ECO — Fastly Compute

**نسخه سبک، سریع و بدون سرور XHTTP Relay روی Fastly Compute Edge**

[![Runtime](https://img.shields.io/badge/Runtime-Fastly_Compute_JS-FF282D.svg?style=for-the-badge&logo=fastly)]()
[![Installer](https://img.shields.io/badge/Windows_Installer-Token_API_Mode-blue.svg?style=for-the-badge)]()
[![Config](https://img.shields.io/badge/Config-Config_Store_(ENV)-2ea44f.svg?style=for-the-badge)]()

**داستان این نسخه چیه؟**
<br>
🟥 **این پروژه نسخه Fastly Compute از XHTTP Relay ECO هست. به جای Vercel، روی شبکه CDN جهانی Fastly با بیش از 70 نقطه حضور (POP) دیپلوی میشه. درخواست‌ها روی Edge پردازش میشن و به سرور اینباند خارجی فوروارد میشن — بدون لایه میانی، بدون بافرینگ، با تاخیر بسیار پایین.**

📣 **جهت دریافت اطلاعات و نکات بیشتر به کانال تلگرامی من مراجعه کنید:** [@B3hnamR](https://t.me/B3hnamR)
📌 **نکته مهم:** لطفاً این راهنما رو تا انتها و با دقت بخونید تا موقع ستاپ کردن هیچ مشکلی براتون پیش نیاد.

> ⚠️ **هشدار:** پروژه رو **Fork نکنید**. برای امنیت بیشتر از دکمه سبز **Code** بالای صفحه روی **Download ZIP** کلیک کنید و از اینستالر ویندوزی استفاده کنید.

</div>

---

## ✨ چرا Fastly Compute؟

| ویژگی | Vercel | Fastly Compute |
| :--- | :---: | :---: |
| **تعداد POP جهانی** | ~20 | **+70** |
| **اجرای کد روی Edge** | ✅ | ✅ |
| **Streaming واقعی** | ✅ | ✅ |
| **Config Store (ENV)** | Dashboard | **API / Installer** |
| **بدون Cold Start** | ⚠️ | ✅ |
| **پلن رایگان** | محدود | **100K req/month رایگان** |
| **هزینه هر میلیون request** | بیشتر | **$0.50** |

---

## 🧠 معماری پروژه

```
کلاینت (xray/v2ray)
        │
        ▼ HTTPS / TLS
┌─────────────────────────┐
│   Fastly Edge (70+ POP)  │  ← نزدیک‌ترین POP به کاربر
│   relay-xxxxx.edgecompute.app │
└────────────┬────────────┘
             │ HTTPS + Config Store
             ▼
┌─────────────────────────┐
│   سرور اینباند خارجی   │
│   xray / v2ray (XHTTP)  │
└─────────────────────────┘
```

**چطور کار می‌کنه؟**

درخواست کلاینت به نزدیک‌ترین POP فستلی میرسه. کد JavaScript روی Edge اجرا میشه، هدرها فیلتر میشن، و درخواست به سرور اینباند خارجی فوروارد میشه. Config Store مقادیر `TARGET_BASE`، `TARGET_HOSTNAME` و `RELAY_PATH` رو به صورت runtime در اختیار کد میذاره — بدون نیاز به redeploy برای تغییر تنظیمات.

---

## 🪟 نصب خودکار روی ویندوز

**پیش‌نیاز:** فیلترشکن روی **TUN Mode** یا System Proxy

۱. فایل ZIP پروژه رو Extract کن
۲. فیلترشکن رو روشن کن
۳. روی `Run-Deploy-Fastly.bat` دابل‌کلیک کن
۴. توکن Fastly رو وارد کن
۵. تنظیمات رو پر کن و Deploy بزن

### ساخت توکن Fastly

۱. وارد [manage.fastly.com](https://manage.fastly.com) بشو
۲. برو به **Account → Personal Tokens**
۳. یک توکن جدید با scope **global** بساز
۴. توکن رو داخل اینستالر پیست کن

توکن به صورت **رمزنگاری‌شده با DPAPI ویندوز** ذخیره میشه:

```text
.fastly-token.dpapi
```

---

## 🎛️ منوی اینستالر

```text
Main Menu:
──────────────────────────────────────────────
[1] New deployment        - ساخت service جدید روی Fastly
[2] Redeploy / update     - بیلد و آپلود مجدد روی service موجود
[3] Manage services       - لیست، ویرایش ENV، حذف سرویس‌ها
[4] Change API token      - تعویض توکن فستلی
[0] Exit
──────────────────────────────────────────────
```

### منوی Manage Services

```text
[1] List all services      - لیست همه Compute service‌های اکانت
[2] View service details   - domain، ENV، timeout یک سرویس
[3] Edit ENV (Config Store)- تغییر TARGET/PATH بدون redeploy
[4] Delete service         - حذف کامل سرویس
[0] Back
```

---

## ⚙️ تنظیمات اینستالر

### مرحله ۱ — Target Domain

آدرس کامل سرور اینباند خارجی با پورت:

```text
https://your-domain.com:2053
```

### مرحله ۲ — Relay Path

مسیری که روی سرور اینباند تنظیم کردی:

```text
/api
```

> `PUBLIC_RELAY_PATH` به صورت خودکار با `RELAY_PATH` یکی میشه.

### مرحله ۳ — Backend Timeouts

| پارامتر | پیش‌فرض | توضیح |
| :--- | :---: | :--- |
| `connect_timeout` | `10000ms` | حداکثر زمان برای برقراری TCP connection به سرور |
| `first_byte_timeout` | `300000ms` | حداکثر زمان انتظار برای دریافت اولین byte از سرور |
| `between_bytes_timeout` | `300000ms` | حداکثر زمان انتظار بین هر دو chunk متوالی داده |

> برای XHTTP streaming، مقادیر بالا توصیه میشه تا بین پکت‌ها قطعی رخ نده.

---

## 🔧 Config Store (معادل ENV)

بعد از deploy، اینستالر یک **Config Store** برای سرویس میسازه و این مقادیر رو توش ذخیره میکنه:

| کلید | مثال |
| :--- | :--- |
| `TARGET_BASE` | `https://your-domain.com:2053` |
| `TARGET_HOSTNAME` | `your-domain.com` |
| `RELAY_PATH` | `/api` |

**مزیت بزرگ:** میتونی این مقادیر رو بدون redeploy تغییر بدی — از منوی **Manage → Edit ENV**، مقدار جدید رو وارد کنی و بلافاصله live میشه.

---

## 💻 کانفیگ کلاینت

بعد از deploy، اینستالر کانفیگ آماده میسازه:

```text
vless://YOUR-UUID@relay-xxxxxxxx.edgecompute.app:443
  ?encryption=none
  &security=tls
  &sni=relay-xxxxxxxx.edgecompute.app
  &fp=chrome
  &insecure=0
  &type=xhttp
  &host=relay-xxxxxxxx.edgecompute.app
  &path=%2Fapi
  &mode=auto
  #XHTTP-Fastly-Compute
```

**نکات مهم:**

- `host` و `sni` باید دامنه Fastly پروژه باشن
- `path` باید با `RELAY_PATH` یکی باشه
- `mode=auto` پیش‌فرضه؛ اگه سرور روی `packet-up` بود، کلاینت هم `packet-up` بذار

---

## 🧪 Health Check

اینستالر بعد از deploy یک تست خودکار میگیره:

| HTTP Code | معنی |
| :--- | :--- |
| `400` یا `404` | ✅ **Relay کار میکنه** — origin جواب داده (برای xhttp طبیعیه) |
| `200` | ✅ Relay کار میکنه |
| `000` | ⏳ DNS هنوز propagate نشده — 1-2 دقیقه صبر کن |
| `500` | ⚠️ Config Store هنوز لینک نشده — redeploy کن |
| `502` | ❌ Backend در دسترس نیست — سرور و پورت رو چک کن |

---

## 🛠️ معنی ارورها

| کد | معنی |
| :---: | :--- |
| `400` | مسیر جواب داده ولی درخواست probe کامل نیست — طبیعیه |
| `404` | مسیر اشتباهه؛ `RELAY_PATH` رو چک کن |
| `500` | Config Store در دسترس نیست یا مقادیر ست نشدن |
| `502` | Fastly به سرور مقصد وصل نشد |
| `503` | سرور مقصد overload یا در دسترس نیست |
| `504` | timeout؛ `first_byte_timeout` رو بالا ببر |

---

## 💸 هزینه روی Fastly

| چیز | مقدار |
| :--- | :--- |
| **پلن رایگان** | 100,000 request/ماه |
| **Compute time رایگان** | 438,000 GB-second/ماه |
| **هر میلیون request اضافه** | $0.50 |
| **هر میلیون GB-second اضافه** | $0.05 |

برای استفاده معمولی VPN، هزینه ماهانه معمولاً **کمتر از $2** میشه.

---

## 📋 فایل‌های پروژه

```text
XHTTPRelayFastly/
├── Deploy-Fastly-Windows.ps1   ← اینستالر ویندوزی
├── Run-Deploy-Fastly.bat       ← لانچر یک‌کلیکی
├── fastly.toml                 ← تنظیمات Fastly Compute
├── package.json                ← وابستگی‌های JS
├── src/
│   └── index.js                ← کد relay روی Edge
└── bin/
    └── main.wasm               ← خروجی build (بعد از npm run build)
```

---

## 🔗 پروژه‌های مرتبط

| پروژه | توضیح |
| :--- | :--- |
| [XHTTPRelayECO](https://github.com/B3hnamR/XHTTPRelayECO) | نسخه Vercel همین پروژه |

---

## ☕ حمایت از پروژه

اگر این پروژه براتون مفید بود:

**Tron (TRX) / USDT (TRC-20):**
```
TTfYReJ7aJEvx4CfwgtY3UV8hJHXTrTwnn
```

**BNB / USDT (BEP-20):**
```
0x25CAc03F80C12FFc30D8264e4b90423AFfA2E6Ac
```

---

## License
@b3hnamrjd
@ShakerFPS
MIT
