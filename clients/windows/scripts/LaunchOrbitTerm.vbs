Option Explicit

Dim shell, appPath
Set shell = CreateObject("WScript.Shell")
appPath = "C:\OrbitTerm-Client\clients\windows\src\OrbitTerm.App\bin\x64\Release\net9.0-windows10.0.19041.0\OrbitTerm.App.exe"
shell.Run Chr(34) & appPath & Chr(34), 1, False
