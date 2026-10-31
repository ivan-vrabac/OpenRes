# Push notifications (optional)

Notifications always work through a check every 15 minutes. Firebase Cloud Messaging makes them
arrive within seconds: the server sends a push with no text, which wakes the app to fetch the
notification from its inbox. It is optional.

## Server

1. In the Firebase console create a project and a service account with the
   "Firebase Cloud Messaging API" role. Download its JSON key.
2. Save it as `deploy/secrets/firebase-service-account.json`. `deploy/secrets/` is
   gitignored, so never commit this file.
3. In `deploy/.env` set:
   ```
   FIREBASE_PROJECT_ID=your-project-id
   GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/firebase_sa
   ```
4. Uncomment the `secrets:` blocks in `deploy/docker-compose.yml` and restart.

## App

Register an Android app with your `APP_ID` in the same Firebase project and put its
`google-services.json` in `app/android/app/` (gitignored). The build uses it when it is there.
