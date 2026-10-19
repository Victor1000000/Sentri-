# Sentri paperwork drafts

Starting points only. They describe what the software actually does today, with blanks for your details. **A Nigerian data-protection lawyer must review everything here before it is sent or published.** Items in [brackets] are yours to fill in. Confirm current regulator requirements yourself (NDPC guidance changes), not from this file.

---

## A. What the system collects (use this for the NDPC form, the DPIA and the privacy notice)

| Data | Why | Where / how protected | Kept for |
|---|---|---|---|
| User's phone number | Sign-in (one-time code) and identifying who is in danger | Encrypted in the database; searches use a keyed hash | While the account exists; 30 days after deletion |
| Emergency contacts' phone numbers (3 to 5, chosen by the user) | To send them alerts | Encrypted | While the account exists |
| Contact's reply to the invitation (accepted / declined) | Honour consent | Database | While the account exists |
| Location (latest position) during an active alert | Show contacts where the user is | Stored in the database as ordinary data, not separately encrypted (rely on disk encryption and access controls, see note below); contacts see it only through a time-limited link | `RETENTION_HOURS` after the alert ends (default 72 hours) |
| Alert record (trigger type, times, state) | Run the alert; investigate misuse | Database | Same as above |
| Cancel PIN and duress PIN | Cancel an alert, or appear to cancel while still alerting | Stored only as slow salted hashes, never readable | While the account exists |
| Device and push token | Deliver alerts to the app | Database | Until the device is removed |
| Admin audit log | Prove who did what | Tamper-evident chain; contains no phone numbers or locations | [your policy, e.g. 12 months] |

**Note for your lawyer and security reviewer:** phone numbers are encrypted field by field, but the latest location on an alert record is not. If you want it encrypted too, that is a code change we should make before launch. Do not describe location as "encrypted in the database" in the notice until it is.

Not collected: contacts list from the phone, microphone or camera data, browsing, advertising identifiers.
Sub-processors to list: [cloud host and region], Termii (SMS), [Firebase / Google, if push is enabled], [map tile and place-name providers if not self-hosted].

## B. Privacy notice (plain English, to be translated into the five languages)

**Who we are.** Sentri is run by [company name, address, contact email]. Our data protection officer is [name, email].

**What Sentri does.** When you start an alert, Sentri sends your emergency contacts a text message with a link showing where you are, and repeats it until one of them says they are responding. Sentri is an aid. It does not guarantee that anyone will respond, and it does not replace calling the emergency services. [Until our agreement with the police is in place: Sentri does not send alerts to the police.]

**What we keep.** Your phone number, the numbers of the contacts you choose, and, only while an alert is active, your location. Location and alert records are deleted [72 hours] after an alert ends. Your PINs are never stored in a readable form.

**Who sees it.** Your contacts see your location only through the alert link. No one at Sentri can read your data on their own: opening anything needs two different administrators to approve, for a limited time, and every step is logged. [Service providers who handle texts and hosting, as listed in section A.]

**Your choices.** You can change contacts, delete your account in the app, and ask us to correct or give you your data at [email]. We reply within [30 days]. You can complain to the Nigeria Data Protection Commission.

**Limits.** A switched-off phone cannot be located. Alerts by text work only with mobile signal or credit.

## C. Contact invitation (what the person you list receives)

The app sends one text message in the contact's language with an accept/decline link (wording is in `backend/src/modules/consent/messages.ts`; each is under 160 characters). The link opens a page that says who asked, what Sentri will send them, and lets them accept or decline. Ask your lawyer: (1) is the invitation enough to rely on for contacts who never answer; (2) the current default is that unanswered contacts still receive emergency alerts, because silence must not block help in a real emergency.

## D. Letter to a police command (to start the conversation)

> [Date]
> The Commissioner of Police, [State] Command
>
> **Request for a meeting on an emergency alert service, Sentri**
>
> [Company] is building Sentri, a mobile app that lets a person in danger alert up to five trusted contacts with their live location. We would like the Command's guidance on being able to share the same alert with your control room.
>
> We ask for: (1) the official telephone and SMS numbers of the control room(s) that should receive such alerts, confirmed in writing; (2) the message format the Command prefers; (3) the contact person for questions and for correcting a number; (4) the Command's position on false alarms.
>
> We will not send any alert to the Command until a written agreement is in place. We will publish the numbers only after the Command confirms them. We do not display or store police positions.
>
> Yours faithfully, [Name, title, phone, email]

**Points for the agreement (MOU):** which lines receive alerts and at what hours; what an alert contains (location link, time, no personal details beyond what the user chose); expected response and its limits (no guarantee); false-alarm handling; how and how often numbers are re-confirmed; who is liable for what; data protection roles; how either side ends the arrangement; a named contact on each side.

## E. Termii sender ID request (adapt to their form)

Purpose: sign-in codes (one-time passwords) and the dispatch message to a police control room that has agreed to receive it. Emergency contacts are NOT texted: their alerts are shown inside the app and pushed. Sender ID requested: [SENTRI]. Expected volume: [messages per month]. Sample messages: the real OTP text and the dispatch text (plain, no marketing, no links). Ask them to confirm the sender ID route works for numbers on Do-Not-Disturb.

## F. Google Play declaration text

- **Play permissions:** SEND_SMS is not requested. Declare foreground service (special use), full-screen intent (emergency alerts that must reach the contact's screen), accessibility (volume gesture), overlay and battery-optimisation exemption.
- **Accessibility service:** "Used only to detect the volume buttons pressed in a set pattern to start an alert discreetly when the screen is off. The service does not read screen content, passwords or any other app. It is optional and off until the user turns it on." Show an in-app disclosure screen before the user is sent to Android settings.
- **Foreground service (specialUse):** "Keeps shake and button triggers working while the app is in the background, so a user can start an alert without opening the app. Shown with a persistent notification."
- **Overlay permission:** "Optional floating alert button the user can place over other apps."
- **Background location and data safety form:** location is collected only during an active alert and for the last-known-position text when the battery is critically low; encrypted in transit; deleted after [72 hours]; users can delete their account in the app.

## G. Terms of service: clauses to include

Sentri is an aid, not an emergency service, and gives no guarantee of response or delivery. Do not rely on it as your only way to get help. A powered-off phone cannot be tracked and texts need signal or credit. Users must only list people who have agreed to be contacts, and must not trigger false alerts; repeated misuse may lead to restrictions. Age rule: [18+ / parental consent for under-18, per your lawyer]. Limitation of liability and governing law: [lawyer].
