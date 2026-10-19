# Sentri legal and partnership checklist

Not legal advice. Have a Nigerian data-protection lawyer review before launch.

## 1. Police partnership
- [ ] Approach the Nigeria Police Force (state commands and the Force headquarters) for a written MOU or letter of authority before Sentri sends anything to any police line.
- [ ] Agree: which lines receive alerts, message format, expected response, out-of-hours handling, who is liable for missed or false alerts.
- [ ] Obtain official control-room numbers by state and LGA, with a named verifier and date. Load only verified rows (`verified_at` set). Re-verify every 6 months.
- [ ] Until signed, keep the dispatcher in `log_only`. Say so in the app so users do not assume police are notified.
- [ ] Set a false-alarm policy (warnings, rate limits) agreed with the police.
- [ ] Never expose police positions or movements in any user-facing screen.

## 2. NDPA (Nigeria Data Protection Act 2023) and GDPR later
- [ ] Register with the Nigeria Data Protection Commission as a data controller/processor of major importance if thresholds apply.
- [ ] Appoint a Data Protection Officer.
- [ ] Complete a Data Protection Impact Assessment (location, phone numbers, third-party contacts, emergency data).
- [ ] Lawful basis: consent for the user; for emergency contacts, document the basis and the contact consent step is built (in-app invitation with accept/decline; no SMS); drafts of the wording are in `docs/paperwork-drafts.md`. Decide with your lawyer whether contacts who have not answered should still receive alerts (current default: yes).
- [ ] Privacy notice in all five languages, plain wording.
- [ ] Data subject rights process: access, deletion, correction, withdrawal; in-app delete account.
- [ ] Retention schedule published and enforced (see deployment guide).
- [ ] Breach response plan with 72-hour notification to the regulator.
- [ ] Data processing agreements with Termii, cloud host, and any push provider. Check cross-border transfer rules for each.
- [ ] Annual compliance audit filing, if required for your category.
- [ ] For EU launch: representative, SCCs for transfers, EU-hosted deployment, GDPR DPIA.

## 3. Telecom and SMS
- [ ] Alerts and location shares to contacts are in-app only (no SMS, no links). SMS is used for sign-in codes and police dispatch.
- [ ] Location sharing: privacy notice covers live location sent to chosen contacts, latest position only, deleted after the retention window, auto-ends after 8 h unless extended.
- [ ] Termii account, registered sender ID (and approval), DND route for transactional alerts, and confirm emergency SMS is allowed on that route.
- [ ] Short link domain registered and allowed by carriers (some filter unknown links).
- [ ] Confirm SMS costs and set the budget guard values to match.

## 4. App stores
- [ ] Google Play declarations: full-screen intent (emergency alerts), foreground service special use, accessibility, overlay. No SEND_SMS.
- [ ] Accessibility Service declaration and in-app prominent disclosure (volume gesture).
- [ ] Foreground service `specialUse` declaration and video/justification.
- [ ] Overlay (`SYSTEM_ALERT_WINDOW`) and battery-optimization exemption justification.
- [ ] Background location disclosure and data-safety form.
- [ ] Apple: location usage strings, App Review notes explaining emergency use, no SMS claims on iOS.

## 5. Product and consumer protection
- [ ] Terms of service: Sentri is an aid, not a guaranteed emergency service; no guarantee of response; do not rely on it as the only means.
- [ ] Clear statement that a powered-off phone cannot be tracked.
- [ ] Age policy: under-18 handling and parental consent rules.
- [ ] Insurance (professional indemnity / cyber).
- [ ] Accessibility and language review.

## 6. Brand
- [ ] Trademark search and registration for "Sentri" in Nigeria (and target markets); the earlier name "Sentry" was a concern, so check similar marks in the safety/security class (Nice classes 9, 38, 42, 45).
- [ ] Secure domains and app-store names.

## 7. Security governance
- [ ] Decide whether to encrypt the stored location on alert records field by field (phone numbers already are). Today it relies on disk encryption and access controls.
- [ ] Independent penetration test before launch.
- [ ] Secrets rotation procedure and key custody (two people).
- [x] Dual-approval admin workflow is built (`/admin`). Still to do: quarterly access review of who holds admin accounts, and keeping database credentials and `DATA_KEY` with different people.
- [ ] Incident and abuse reporting channel for users and contacts.
