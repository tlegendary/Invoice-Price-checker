# Publishing ChargeCheck on the App Store

You don't need a Mac. Apple handles the payments, and Codemagic builds the app in the cloud.
Allow a few hours spread over 2–3 days, mostly waiting for Apple.

Things to keep to hand:
- Bundle ID: `com.rjapps.invoicepricechecker`
- Subscription product IDs, which must be typed exactly like this: `ipc_monthly` and `ipc_yearly`
- Privacy policy and support page: https://claude.ai/artifact/QQvsC9D53oM1TCk37x1HVD
  On that page, tap **Share** and turn on the public link so anyone can open it.

---

## Step 1: Set up App Store Connect (https://appstoreconnect.apple.com)

1. **Business › Agreements, Tax and Banking.** Accept the **Paid Apps** agreement, then add your bank account and tax form (a UK individual fills in the W-8BEN). You can't sell subscriptions until this shows as Active.
2. **Small Business Program.** Apply at https://developer.apple.com/app-store/small-business-program/ so Apple takes 15% instead of 30%.
3. **Register the Bundle ID** at https://developer.apple.com/account/resources/identifiers:
   **+** › App IDs › App, then fill in:
   - Description: ChargeCheck
   - Bundle ID (Explicit): `com.rjapps.invoicepricechecker`
   - In-App Purchase is switched on automatically.
   Then tap Continue › Register.
4. **Create the app.** Go to **Apps › + › New App** and fill in:
   - Platform: iOS
   - Name: **ChargeCheck: Invoice Checker**. Subtitle: **Catch supplier overcharges**.
   - Primary language: English (U.K.)
   - Bundle ID: the one you just registered
   - SKU: `ipc001`
   - User access: Full Access
5. **Create the subscriptions.** In your app, go to **Monetization › Subscriptions**:
   - Create a subscription group called **ChargeCheck Pro**.
   - Add a subscription with Reference name **Monthly**, Product ID `ipc_monthly`, duration 1 month and price £9.99.
   - Add a subscription with Reference name **Yearly**, Product ID `ipc_yearly`, duration 1 year and price £89.99.
   - On **each** one:
     - Under **Subscription Prices**, set the price.
     - Under **Introductory Offers**, choose Free, 7 days, all countries.
     - Under **App Store Localization**, add a Display name ("Monthly" / "Yearly") and a Description ("Full access to ChargeCheck").
     - Under **Review Information**, upload `5_subscription-review.png` from the screenshots folder.
6. **App Privacy.** Choose **Data Not Collected**. For the Privacy Policy URL, use the link above.
7. **App Information.** Category: **Business**. Fill in the age rating questions; answering "None" to everything gives 4+.
8. **Create an API key for Codemagic.** Go to **Users and Access › Integrations › App Store Connect API › +**:
   - Name: Codemagic, Access: **Admin**, then Generate.
   - **Download the .p8 file.** You can only download it once.
   - Write down the **Issuer ID** and **Key ID** shown on that page.
9. **Note your app's Apple ID.** It's the number under **App Information › Apple ID**, for example 6739012345.

## Step 2: Put the project on GitHub (free)

1. Sign up at https://github.com and create a **New repository** called `invoice-price-checker`. Make it **Private**.
2. Tap **uploading an existing file**, then drag in **everything** from this unzipped folder (the `www`, `ios` and other folders and files), and commit.
3. Open `codemagic.yaml` in GitHub, tap the ✏️ pencil, and replace `0000000000` with your app's Apple ID from step 1.9. Commit.

## Step 3: Build in the cloud with Codemagic (free: 500 build minutes a month)

1. Sign up at https://codemagic.io **using your GitHub account**.
2. Choose **Add application**, then GitHub, then `invoice-price-checker`. When asked, choose **codemagic.yaml**.
3. Go to **Team settings › Team integrations › Developer Portal › Connect** and fill in:
   - Name: **AppStoreKey**. It must be exactly this.
   - Issuer ID and Key ID from step 1.8.
   - The .p8 file.
4. Go to **Team settings › codemagic.yaml settings › Code signing identities**:
   - **iOS certificates › Generate certificate**: choose AppStoreKey and the Apple Distribution type, then save.
   - **iOS provisioning profiles › Fetch profiles**: choose the **App Store** profile for `com.rjapps.invoicepricechecker`, then save.
5. Go back to the app and choose **Start new build**, then the workflow **ChargeCheck – App Store**.
   It takes about 15–25 minutes. When it finishes, the app is uploaded to App Store Connect and TestFlight by itself.

## Step 4: Test it on your iPhone

1. In App Store Connect, open **TestFlight** and add yourself as an internal tester.
2. Install the **TestFlight** app on your iPhone and open ChargeCheck from it.
3. Check these things:
   - The free trial starts. Purchases in TestFlight are free.
   - **Restore purchases** works.
   - Scanning works, photos and PDFs open, and reports save.

## Step 5: Submit for review

In App Store Connect, open **Apps › ChargeCheck › iOS App 1.0** and fill in the following.

- **Screenshots (6.9-inch / 6.7-inch display):** upload `1_result.png`, `2_review.png`, `3_reports.png` and `4_credit.png`. They are already the right size.
- **Promotional text:** Find out how much your suppliers overcharge you – in seconds.
- **Description:**
  > ChargeCheck reads your supplier invoices and tells you exactly how much you were overcharged.
  >
  > • Scan a photo or upload a PDF invoice – everything is read on your iPhone, nothing is uploaded
  > • Every invoice is double-checked: read twice, totals checked, every item matched to your agreed prices
  > • See every overcharge, line by line, and the total you should have paid
  > • Send a ready-written credit request to your supplier by WhatsApp or email
  > • Track credits owed and received
  > • Prices per supplier, folders for each of your shops, monthly reports
  > • Your prices update automatically when a supplier charges less
  > • Works offline
  >
  > Start with a 7-day free trial, then choose monthly or yearly.
- **Keywords:** invoice,price,check,overcharge,supplier,restaurant,takeaway,wholesale,cost,food,margin,credit
- **Support URL** and **Privacy Policy URL:** the link at the top of this guide.
- **Copyright:** 2026 RJ
- **Build:** choose the build Codemagic uploaded.
- **In-App Purchases and Subscriptions:** tick **ipc_monthly** and **ipc_yearly**. Your first subscriptions have to be submitted together with the app.
- **App Review Information:**
  - Sign-in required: **No**.
  - Notes: "No account needed. Tap Start free trial on the first screen (sandbox). Tap 'Scan or upload invoices' and choose any photo of a supplier invoice. Support: r93.hamad@gmail.com"
- Choose **Add for Review › Submit**. Apple usually replies within 1–3 days.

## Making changes later
Send me the change you want. I'll give you an updated `www/index.html`. Upload it to GitHub in place of the old one, then start a new build in Codemagic. Each new build gets a higher build number automatically.
