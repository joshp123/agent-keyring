<!-- Written by AI on 2026.11.11 by model gpt-6.1-terra. -->

# Agent Keyring test

The agent runs the test and handles the buttons. You compare codes and use
Touch ID or Face ID. Every code has eight groups: **all eight must match**.
If they do not, stop.

The app screens and touch counts below are **estimates from the code**. They
have not been measured on the devices. Apple may ask for extra authentication.

1. **Apple sign-in.** Approve the sign-in if Apple asks. The agent sets up
   notifications. Expected: the agent says notifications are ready.
2. **Rules.** Confirm with Touch ID. Expected: `example.com` appears as Ask.
   **Estimated: 1 touch.**
3. **Connect the Mac.** Compare the two codes. If they match, use Touch ID.
   Expected: the Mac says it is connected. **Estimated: 1 touch.**
4. **Connect the mini and Linux machine.** For each machine, compare the two
   codes. If they match, use Touch ID. Expected: both appear in Machines.
   **Estimated: 2 touches.**
5. **Connect the iPhone.** Compare the code on the phone with the one on the
   Mac. If they match, use Touch ID on the Mac. Expected: the phone says
   “Paired”. **Estimated: 1 touch.**
6. **Keep typing.** Keep typing in another app while a request appears. Your
   typing must stay in that app. Check that the request says `example.com`,
   then approve with Touch ID. Expected: the agent says the test succeeded.
   **Estimated: 1 touch.**
7. **Approve on the phone.** Check the `example.com` request and approve with
   Face ID. Expected: the agent says the test succeeded without a Mac approval.
   **Estimated: 1 Face ID.**
8. **Close the MacBook.** Approve the next `example.com` request on the phone
   with Face ID. Keep the lid shut until the agent confirms the test succeeded.
   **Estimated: 1 Face ID.**
9. **Test Automatic.** Open the lid. Confirm the change to Automatic with
   Touch ID. Expected: the agent succeeds without another approval. Confirm
   the change back to Ask with Touch ID. **Estimated: 2 touches.**
10. **Remove and reconnect the phone.** Confirm removal with Touch ID. Compare
    the new codes on the phone and Mac; if they match, use Touch ID. Expected:
    the phone says “Paired” again. **Estimated: 2 touches.**

The agent checks denial, expiry and release afterwards. If a screen or result
is different, stop and let the agent investigate.
