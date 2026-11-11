<!-- Written by AI on 2026.11.11 by model gpt-6.1-terra. -->

# Agent Keyring: real-device sitting card

**Draft, not ready to run.** The screens and counts below come from the code,
not a real-device rehearsal. The agent must first arrange the APNs key and
verify that Passwords can export a selected dummy login to the test app.
Stop if a code differs, the test app cannot be distinguished, a real password
would be exported, or a prompt is unexpected.

The agent operates the devices and starts each request. Josh compares the
codes and uses the sensors. The numbers below are estimates of biometric
confirmations, not counts measured on the devices. Apple may ask for additional
authentication.

1. **Apple account:** approve the sign-in on the trusted device if Apple asks.
   The agent creates a sandbox push key for the test phone and configures the
   test relay. This is needed for the background notification test.
2. **Import:** the agent opens Agent Keyring Test and Passwords, selects the
   dummy login and starts its export to Agent Keyring Test. Confirm the export
   when Apple asks. Expected: the test app shows the imported login. **Apple
   authentication count unknown.** Do not export real logins for this test.
3. **Connect the Mac:** compare all eight groups shown in the test app with
   the relay code the agent shows. If they match, confirm with Touch ID.
   Expected: the test app says the relay is connected. **Estimated: 1 touch.**
4. **Connect the two machines:** for each of the mini and Linux, compare all
   eight groups in the Mac panel with the code the agent shows from that
   machine. If they match, confirm with Touch ID. The agent enables Automatic
   access for both test machines. Expected: each appears in Machines.
   **Estimated: 2 touches.**
5. **Pair the phone:** the agent opens the test app on the iPhone and starts
   pairing. Compare all eight groups on the phone and Mac. If they match,
   confirm on the Mac with Touch ID. Expected: the phone says “Paired”.
   **Estimated: 1 touch.** The agent waits for the dummy login to sync.
   When the agent changes the dummy login's rule for the Automatic test,
   confirm the shown rule with Touch ID. **Estimated: 1 additional touch.**
6. **Typing test:** keep typing in another app while the agent starts a dummy
   request. The request must appear without taking your keystrokes. Check the
   login, machine and reason, then approve with Touch ID. Expected: the agent's
   dummy program succeeds. **Estimated: 1 touch.**
7. **Phone approval:** the agent starts a new dummy request. Open the phone
   notification, check the login, machine and reason, and approve with Face ID.
   Expected: the dummy program succeeds without a Mac approval.
   **Estimated: 1 Face ID.**
8. **MacBook shut:** close the lid. The agent starts another dummy request.
   Open the notification and approve with Face ID. Expected: the dummy program
   succeeds while the lid stays shut. **Estimated: 1 Face ID.**
9. **Remove the phone:** open the lid. The agent starts phone removal; confirm
   with Touch ID. Expected: the removed phone can no longer approve after the
   other devices receive the change. The agent re-pairs it; compare the codes
   and confirm with Touch ID. **Estimated: 2 touches.**

The agent checks Automatic access, denial, release and expiry without keeping
Josh at the keyboard. If any step fails, record the result and stop; do not
call the sitting a pass.
