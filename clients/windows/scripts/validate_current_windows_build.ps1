$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Set-Location $repositoryRoot

dotnet restore 'clients\windows\tests\OrbitTerm.Security.Tests\OrbitTerm.Security.Tests.csproj' `
    -p:RuntimeIdentifier=win-x64
if ($LASTEXITCODE -ne 0) {
    throw "Windows restore failed with exit code $LASTEXITCODE."
}

dotnet test 'clients\windows\tests\OrbitTerm.Security.Tests\OrbitTerm.Security.Tests.csproj' `
    --configuration Release `
    -p:RuntimeIdentifier=win-x64 `
    --logger 'console;verbosity=normal'
if ($LASTEXITCODE -ne 0) {
    throw "Windows security test suite failed with exit code $LASTEXITCODE."
}

dotnet restore 'clients\windows\src\OrbitTerm.App\OrbitTerm.App.csproj' `
    -p:Platform=x64 `
    -p:RuntimeIdentifier=win-x64
if ($LASTEXITCODE -ne 0) {
    throw "Windows app restore failed with exit code $LASTEXITCODE."
}

dotnet build 'clients\windows\src\OrbitTerm.App\OrbitTerm.App.csproj' `
    --no-restore `
    --configuration Release `
    -p:Platform=x64 `
    -p:RuntimeIdentifier=win-x64 `
    -p:PublishReadyToRun=false
if ($LASTEXITCODE -ne 0) {
    throw "Windows x64 Release build failed with exit code $LASTEXITCODE."
}
