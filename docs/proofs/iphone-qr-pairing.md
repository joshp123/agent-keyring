# iPhone QR pairing

Written by AI on 2026.10.12 by model GPT-6 (Codex).

## Pair on Josh's devices

1. Build and run **AgentKeyring** from `AgentKeyring.xcodeproj` on the Mac,
   and **AgentKeyringPhone** from `AgentKeyringPhone.xcodeproj` on the physical
   iPhone, using the existing development team and provisioning. These unsigned
   proof builds are not installable device builds. Use the same iCloud account
   and CloudKit environment on both devices and the notification extension.
   Once the schema is deployed, pin `Production` in all three targets.
   For a fresh schema, keep the phone app closed until the Mac is ready to pair.
2. Open the Mac app's main window. If **Add iPhone** is disabled because the
   access rules need confirmation, open **Access Rules…** and confirm those
   rules through the existing authentication prompt first.
3. Click **Add iPhone** on the Mac. Keep the QR sheet open. The code expires
   five minutes after creation; closing the sheet cancels it.
4. On the iPhone, open Agent Keyring and tap **Pair with Mac**. Allow Camera
   access when prompted. Point the camera at the Mac's QR code. Scanning stops
   after the first QR. An unsupported device, denied camera access, or a failed
   upload shows an error instead of claiming success.
5. Wait for **Request sent. Finish pairing on your Mac.** on the iPhone. The
   Mac polls the pairing record every two seconds. Check the device name on
   the Mac and type the six-digit code shown on the iPhone into the Mac sheet.
   The confirmation button stays disabled until the code matches the received
   key. If it does not match, cancel on the Mac and create a fresh QR.
6. Before the code expires, click **Add iPhone with Touch ID** on the Mac and
   complete the existing signed-store authentication. The sheet says
   **iPhone added.** and the main window lists the phone. Click **Done**.
7. For the first notification run, close the phone app, lock the Mac, and send
   an agent login request. Wait until the Mac saves `ApprovalRequest` to
   CloudKit, then relaunch the phone so its subscription can be saved against
   the existing record type. Send a new request to test notification delivery.
   A subscription attempt before the type exists may fail; pairing itself
   does not need that subscription.
8. To revoke it, click **Remove iPhone** beside its name in the same Mac window
   and complete the signed-store authentication. The phone disappears from the
   list and its key is no longer trusted for approval decisions.

The iPhone's name comes from `UIDevice.current.name`; iOS may report the generic
name “iPhone”. Enter the phone code even when names match. “Request sent”
only means CloudKit accepted the pairing request. Trust begins after the Mac's
signed-store save.

The [CloudKit schema and pairing contract](../cloudkit-approval-channel.md)
describe record storage, code derivation and HMAC authentication.

Physical camera scanning, live CloudKit pairing, Secure Enclave persistence
and Mac authentication require signed runs on Josh's devices.
