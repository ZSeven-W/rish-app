# ZCode account connection in Rish

This is an experimental iOS account connection using the browser/polling
flow observed in the official ZCode 3.11.2 client. It does not embed the
official ZCode agent runtime. The public
[connection guide](https://zcode.z.ai/cn/docs/configuration) distinguishes
BigModel/Z.ai account connection from API-key access; API keys may also use
Coding Plan, so API-key access is not necessarily pay-as-you-go.

## User flow

1. Open **Settings → Runtime Engine** in Rish.
2. Expand **zcode** to open its subscription account panel.
3. Choose BigModel or Z.ai and sign in on the official authorization page.
   iOS uses a system Safari view inside Rish.
4. After account connection, choose **Use subscription / Verify subscription**
   for the selected region's personal Coding Plan.
   Account sign-in and usable model access are separate states.
5. Use **Use API key** to return to the separately stored manual key. The native
   trial routes described below remain available internally; the current GPUI
   subscription panel does not select trial allowance automatically.

The account connection is independent from Rish's reserved general account
and the Codex/Claude official-CLI login interfaces.

## Observed protocol

The iOS implementation uses the official ZCode HTTPS origin for login
initialization and polling. Each explicit login creates a new cryptographic
poll bearer, validates the returned authorization URL, and respects expiry,
cancellation, and retry bounds. BigModel and Z.ai have distinct host/path/query
allowlists and exact HTTPS callbacks under the official origin.

OAuth material and selected model credentials remain in separate device-only
Keychain services. Neither is returned to the application UI. Selecting subscription
credentials clears the effective credential until personal-plan verification
succeeds; a failed check never falls back to the manual key.

The current resolver reads an existing ZCode-named key in a personal project;
it does not create keys or select team projects. Subscription verification
is required again after the local 15-minute verification lease expires.
There is no invented OAuth refresh endpoint: expired vendor authorization
requires a new sign-in. Sign-out removes local authorization and the selected
provider's derived credential, not a server-side key or the manual key.

### Trial allowance

The official client's trial connection uses a separate ZCode-hosted service:
`GET https://zcode.z.ai/api/v1/zcode-plan/billing/balance` and
`POST https://zcode.z.ai/api/v1/zcode-plan/anthropic`.
These use the ZCode token saved by the account authorization, not the personal
project API key. The request path does not append `/v1/messages`.

Rish keeps trial selection explicit (`bigmodel_trial` or `zai_trial`). A failed
trial check must not switch to a personal subscription, manual key, or general
API balance. An empty personal subscription list is expected for a trial
account. Live trial inference still needs separate verification; account
sign-in does not establish it.
