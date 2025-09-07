# GlucoseSync

GlucoseSync is an iOS app that copies glucose readings from Abbott's Libre 3 sensor into Apple Health so other health apps can use the data. The project is written in SwiftUI and communicates only with the LibreView cloud and HealthKit; no third-party server is involved.

## How It Works
1. **Login** – The user enters their LibreView credentials. The app sends them to the LibreLinkUp API at `https://api-de.libreview.io/llu/auth/login` and receives an access token and account identifier.
2. **Download** – Using that token it calls `/llu/connections/{accountId}/graph` to obtain the latest glucose measurements.
3. **Store** – Each reading is converted from mg/dL to mmol/L and written to Apple Health through HealthKit (`HKHealthStore`). A unique sync identifier is attached so that duplicate samples are avoided on subsequent runs.

No information is stored outside the device, and the credentials are kept in the system Keychain.

## Screenshot
A screenshot with three panels—the Libre 3 dashboard, GlucoseSync interface, and the resulting entry in the Health app—will appear here:

![Placeholder screenshot showing three screens](docs/screenshot.png)
