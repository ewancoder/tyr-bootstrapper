#!/usr/bin/env bash
source config.sh
tyrbs="$(pwd)"
read -p "Creating a new project in $folder"

# TODO: create git repo before initializing angular project, or it creates internal repo

# Main folder

mkdir -p "$folder"
cd "$folder"
git init
git branch -m main
echo "# $projectName" > README.md
cp "$tyrbs/LICENSE" LICENSE
cp "$tyrbs/root-gitignore" .gitignore
cp "$tyrbs/docker-compose.yml" docker-compose.yml
cp "$tyrbs/swarm-compose.yml" swarm-compose.yml
sed -i "s/overlab/$dockerProjectName/g" docker-compose.yml
sed -i "s/overlab/$dockerProjectName/g" swarm-compose.yml
cp "$tyrbs/.env.prod" .env.prod
cp "$tyrbs/.env.dev" .env.dev
sed -i "s/overlab/$dockerProjectName/g" .env.prod
sed -i "s/overlab/$dockerProjectName/g" .env.dev
mkdir -p .github/workflows
cp "$tyrbs/deploy.yml" .github/workflows/deploy.yml
sed -i "s/apiFolder/$apiFolder/g" .github/workflows/deploy.yml
sed -i "s/webFolder/$webFolder/g" .github/workflows/deploy.yml
sed -i "s/OverLab.Api/$apiProjectName/g" .github/workflows/deploy.yml
sed -i "s/overlab/$dockerProjectName/g" .github/workflows/deploy.yml
sed -i "s/frontend/$webFolder/g" .github/workflows/deploy.yml
sed -i "s/backend/$apiFolder/g" .github/workflows/deploy.yml

# Api

mkdir -p "$apiFolder"
cd "$apiFolder"
cp "$tyrbs/api-gitignore" .gitignore
cp "$tyrbs/api-editorconfig" .editorconfig

dotnet new sln --name "$solutionName"
dotnet new webapi --no-https --name "$apiProjectName"
cp "$tyrbs/api-Directory.Build.props" Directory.Build.props
cp "$tyrbs/api-Directory.Packages.props" Directory.Packages.props
cp "$tyrbs/api-csproj" "$apiProjectName/$apiProjectName.csproj"
cp "$tyrbs/Program.cs" "$apiProjectName/Program.cs"
sed -i "s/OverLab/$solutionName/g" "$apiProjectName/Program.cs"

find "$apiProjectName" -name "*.http" | xargs rm
find "$apiProjectName" -name "*.json" | xargs rm
cp "$tyrbs/api-HostExtensions.cs" "$apiProjectName/HostExtensions.cs"
cp "$tyrbs/api-Dockerfile" "$apiProjectName/Dockerfile"
sed -i "s/OverLab.Api/$apiProjectName/g" "$apiProjectName/Dockerfile"

mkdir -p "$apiProjectName.Tests"
cp "$tyrbs/tests.csproj" "$apiProjectName.Tests/$apiProjectName.Tests.csproj"
sed -i "s/OverLab.Api/$apiProjectName/g" "$apiProjectName.Tests/$apiProjectName.Tests.csproj"
cp "$tyrbs/ApiTests.cs" "$apiProjectName.Tests/ApiTests.cs"
sed -i "s/OverLab.Api/$apiProjectName/g" "$apiProjectName.Tests/ApiTests.cs"

dotnet sln add "$apiProjectName"
dotnet sln add "$apiProjectName.Tests"
dotnet sln migrate # Do after all projects have been added.

# Database

cd ..
dbmate new initial
echo """-- migrate:up
CREATE TABLE initial();

-- migrate:down
DROP TABLE initial();""" > db/migrations/*.sql

# Frontend

#ng new "$frontendProjectName" --prefix "$angularPrefix" --directory "$webFolder" --skip-tests --zoneless --style scss --defaults true --file-name-style-guide 2016
ng new "$frontendProjectName" --prefix "$angularPrefix" --directory "$webFolder" --skip-tests --zoneless --style scss --defaults true
cd "$webFolder"
rm package-lock.json
rm -rf node_modules
pnpm i
pnpm i --save-dev prettier
cp "$tyrbs/.prettierrc.json" .prettierrc.json
ng add @angular-eslint/schematics --skip-confirmation

# TODO: fix this, it doesn't work
sed -i '/\*\.ts/a\
indent_size = 4
' .editorconfig

cp "$tyrbs/nginx.conf" nginx.conf
cp "$tyrbs/web-Dockerfile" Dockerfile
sed -i "s/overlab/$dockerProjectName/g" Dockerfile
cp "$tyrbs/config.ts" src/config.ts
cp "$tyrbs/config.production.ts" src/config.production.ts
cp "$tyrbs/config.development.ts" src/config.development.ts
sed -i "s/overlab/$dockerProjectName/g" src/config.ts
sed -i "s/overlab/$dockerProjectName/g" src/config.production.ts
sed -i "s/overlab/$dockerProjectName/g" src/config.development.ts
ng generate config karma
pnpm i --save-dev karma-sabarivka-reporter
cp "$tyrbs/app.component.spec.ts" src/app/app.component.spec.ts
pnpm i --save-dev @stryker-mutator/core @stryker-mutator/karma-runner
cp "$tyrbs/sonar-project.properties" sonar-project.properties
sed -i "s/overlab/$dockerProjectName/g" sonar-project.properties
cp "$tyrbs/stryker.config.json" stryker.config.json

git add --all
git commit -m "Initial commit"
git remote add origin https://github.com/ewancoder/$github


