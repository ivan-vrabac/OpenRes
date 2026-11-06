# Privacy Policy for OpenRes

Version {version}

This policy applies to the OpenRes game (the Android app "OpenRes" and its game server) and explains which personal data the game uses, why, who receives it, how it is protected and how long it is kept. The controller is {operator}. We run the game from the Republic of Croatia, our server is located there, and we follow Croatian law and the EU General Data Protection Regulation (GDPR).

## In short

We use your data only to run the game. We don't use it for marketing or advertising, we don't sell it, and we don't give it to third parties, except where this policy says so. There are no ads and no analytics or tracking tools in the game.

## What we process and why

Where no other legal basis is named below, we process the data to perform our agreement with you, that is to run the game for you (GDPR Art. 6(1)(b)).

- **Account:** your company name, your Google account ID and email address if you sign in with Google (never shown to other players), a securely hashed password if your account has one, and sign-in sessions. Needed to give you an account (GDPR Art. 6(1)(b), performing our agreement with you).
- **Country:** Cloudflare tells our server which country your IP address is in, and the server keeps that country with your account. It is used for your flag, the country rankings and the Campus pins on the zoomed-out map (GDPR Art. 6(1)(f), legitimate interest). Your phone's location is not used for this.
- **Game data:** your Campus, hexes, plants, supervisors, stored items, credits, market orders, quests, achievements, rankings and your activity log. The positions of your Campus and hexes are places on the map that you chose; other players see them.
- **Your location (precise):** the game is played on a real map. The app uses your phone's location only while the app is open, to show the map around you. When you do something that depends on where you are (place or move your Campus, visit it, build a hex), your position at that moment is sent to the server to check the distance, and your last position is kept to detect impossible jumps (cheating). We don't collect your location while the app is closed and we don't build a location history. The app explains this before Android asks for the permission. On Android the position comes from Google Play services. The app does not use activity recognition or any other health or fitness data.
- **Activity log:** a list of what your company did (for example building a hex or selling items), with the place where it happened, kept for 7 days so you can look it up in the app.
- **Reports and moderation:** when a player reports another player (for example for an offensive company name or cheating), we keep the report, moderation records and any ban that has ended for up to 1 year, to keep the game safe (GDPR Art. 6(1)(f)). A permanent ban is kept for as long as the account exists. Moderators can change an offensive company name without asking you.
- **Notifications:** the notifications the game sends you, kept on the server (at most the last 200) so your phone can fetch them, and a push token for your phone. Google's Firebase Cloud Messaging uses that token to wake the app; the text of a notification doesn't pass through Google.
- **Contact form:** what you write to us and the reply address you give, to answer you (GDPR Art. 6(1)(f)), kept until your request is handled and at most 1 year.
- **App and device check:** the app asks Google Play to confirm that it is the real app from Google Play on a genuine device, and our server keeps the result (for example whether the device passed and whether Play Protect found a problem), to keep the game fair (GDPR Art. 6(1)(f), legitimate interest). If the check fails, some game actions (for example surveys and market trades) are blocked until it passes. You can ask us to look at this through the contact form.
- **Cheating checks:** when the game sees a position jump nobody could travel, a failed app and device check, or a fake (simulated) GPS position, the server keeps a short record of it (when, what and where) so moderators can look into cheating (GDPR Art. 6(1)(f), legitimate interest). It is kept for up to 1 year.
- **Device ID:** a one-way scrambled (hashed) form of Android's ID for this app on your phone, to recognise several companies played from the same phone (one person, one company; GDPR Art. 6(1)(f), preventing cheating). It is not used for ads and never shared. Kept as long as your account exists.
- **Technical data:** IP address, device and app version and server logs, needed to run and protect the service (GDPR Art. 6(1)(f), legitimate interest).

## Who else receives data

- **Other players** see your company name, Campus level, country, public profile, rankings and the positions of your Campus and hexes on the map. Your own position is never shown to them.
- **OpenStreetMap** (OpenStreetMap Foundation, United Kingdom) delivers the map pictures directly to your phone, so it receives your IP address and the map area you look at (see the OpenStreetMap privacy policy).
- **Cloudflare** (Cloudflare, Inc., USA) sits in front of our game server and website: all connections pass through it, so it receives your IP address and the data sent, to protect the service against attacks and to tell us your country. Its Turnstile check also protects the contact form on the website (see Cloudflare's privacy policy).
- **ip-api.com** was used to find your country by app versions before 0.2.13, so those versions send it your IP address. It receives nothing else, and the game no longer uses it from version 0.2.13.
- **Google** provides location services and app distribution on Android phones, and handles the purchase of the game and its payment; we never see your payment details. If you use Google Play Games, Google signs you in and receives the achievements you earn (see Google's privacy policy).
- **Our hosting:** the game server runs on our own hardware in Croatia. **Google** stores our backups in our private Google Drive account.
- **Authorities**, only where the law requires it.

Google and Cloudflare may process data outside the European Union, including in the USA, and OpenStreetMap is based in the United Kingdom. Such transfers rely on an EU adequacy decision (for the USA, the EU-US Data Privacy Framework for certified companies) or on the EU's standard contractual clauses.

We don't sell or rent personal data and we don't share it for marketing ("we do not sell or share your personal information", also in the sense of US state privacy laws such as the CCPA).

## How we protect your data

- All connections between the app and the server are encrypted (HTTPS/TLS).
- Passwords are stored only as salted hashes; nobody, including us, can read them.
- Sign-in sessions are signed and expire; repeated wrong passwords are blocked for a while.
- Other players get only a random public id for you, never your internal account id.
- The server and its backups are only accessible to the operator.

## How long we keep data

- Account and game data: as long as your account exists.
- Activity log: 7 days. Reports, moderation records, cheating check records, ended bans and contact messages: up to 1 year.
- Server logs and backups: at most 30 days.
- When you delete your account (in the app: Settings › Account › Delete account, or on https://resources.vrabac.eu/delete.html), your company and all its game data are deleted. Accounts younger than 30 days are deleted at once; older accounts are deleted after a 30-day waiting period, during which signing in cancels the deletion (this protects against mistakes and stolen passwords). After deletion, copies in logs and backups disappear within 30 days. Moderation records and contact messages can still name your company until their 1 year limit; market trades stay for the other company, without your company. We keep nothing else about deleted accounts.

## Your rights

Under the GDPR you can ask for access to your data, correction, deletion, restriction, data portability, and you can object to processing based on legitimate interest. You can delete your account yourself at any time (see above). For anything else, use the contact form below. You also have the right to complain to a supervisory authority, in Croatia the Personal Data Protection Agency (AZOP, azop.hr).

## Children

You must be at least 16 to play, or have the permission of a parent or guardian, and we don't knowingly collect data from children under 13 (also in the sense of the US COPPA). If you believe a child has created an account, contact us and we will delete it.

## Changes

We may change this policy at any time, for example if we start using new services. The current version is always in the game (More › Privacy policy) and on https://resources.vrabac.eu/privacy.html, and any change is shown to you when you open the game: you can accept it and keep playing, or decline it, in which case the game closes.

## Contact

{contact}
