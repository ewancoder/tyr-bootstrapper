# TyR project bootstrapper

I created this bootstrapper to help myself spin up new pet projects on my personal infrastructure.

## Instructions

0. Update to latest dotnet and npm/node & angular cli
1. Update year in the `LICENSE` file if needed
2. Update .NET version if needed in Dockerfile and in deploy.yml
3. Update variables in `config.sh` file
4. Update .env.dev file - set unique ports for local dev
5. Run `bootstrap.sh`
6. Set up repo secrets
7. Set up sonarcloud monorepo for the 2 projects (backend/frontend)
8. Add badges to readme

!!!!! BEFORE PUSHING - create DATA in production (and dev if needed)
- And I need to either update deploy.yml or deploy first time manually - cause DB doesn't exist initially and we won't be able to run migrations until it does.

## Repo secrets

- GIST_SECRET: profile, settings, developer settings, PAT tokens (classic), infinite token with gist permission
- HOST, USERNAME, PASSWORD, KEY, PORT
- HOST_DEV, USERNAME_DEV, PASSWORD_DEV, KEY_DEV, PORT_DEV
- API_SONAR_TOKEN, WEB_SONAR_TOKEN

## Frontend manual work

- Update favicon
- Use OnPush in app.component.ts, remove title field, adjust title in index.html
- configure karma.conf.js like in the template (for sabarivka)
- go through all files, re-save them, remove extra comments or unneeded data
- rename app.ts to app.component.ts etc, for now manually
- set indent_size for Typescript! only 4 characters in .editorconfig

## Additional notes

1. Install Prettier & ESLint to VS Code / Rider, turn on Automatic prettier + Run on save, Automatic ESLint + Fix on save

## How to change package scope for ghcr package (super unintuitive and frustrating hence the guide)

1. Go to "Your profile" after clicking personal photo in github top right corner
2. Click "Packages" tab
3. Search for package, click settings on the bottom right
4. Just delete the package at the bottom lol faster and easier
4.1. OR - add repository (button on the right, prior to the list of repositories)

- Also don't forget to copy data on server & add new Seq API keys.
