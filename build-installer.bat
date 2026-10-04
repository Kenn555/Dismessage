@echo off
setlocal
chcp 65001 >nul
title Dismessage - installateur Windows

rem Construit dist\Dismessage-Setup.exe : compile l'appli Windows (release),
rem puis l'empaquette avec Inno Setup (installers\dismessage.iss).
rem Usage : double-clic. "build-installer.bat --skip-build" reutilise la
rem derniere compilation de l'appli.

set "ROOT=%~dp0"

rem Inno Setup 6 : installation par utilisateur, puis emplacements classiques.
set "ISCC=%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe"
if not exist "%ISCC%" set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if not exist "%ISCC%" set "ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe"
if not exist "%ISCC%" (
  echo [ERREUR] Inno Setup 6 introuvable. Installez-le : https://jrsoftware.org/isdl.php
  goto fail
)

rem Runtime Visual C++ livre avec l'appli (le plus recent des Build Tools).
set "CRT="
for /d %%d in ("%ProgramFiles(x86)%\Microsoft Visual Studio\2022\*") do (
  for /d %%v in ("%%d\VC\Redist\MSVC\14.*") do (
    if exist "%%v\x64\Microsoft.VC143.CRT\vcruntime140.dll" set "CRT=%%v\x64\Microsoft.VC143.CRT"
  )
)
if not defined CRT (
  echo [ERREUR] Runtime Visual C++ introuvable ^(Visual Studio Build Tools 2022^).
  goto fail
)

rem Version de l'appli (pubspec.yaml), sans le numero de build "+N".
set "VERSION="
for /f "tokens=2 delims=: " %%v in ('findstr /b "version:" "%ROOT%app\pubspec.yaml"') do set "VERSION=%%v"
for /f "tokens=1 delims=+" %%v in ("%VERSION%") do set "VERSION=%%v"

if /i "%~1"=="--skip-build" goto package
echo [1/2] Compilation de l'appli Windows...
pushd "%ROOT%app"
call flutter build windows --release
if errorlevel 1 (popd & echo [ERREUR] Compilation Windows echouee. & goto fail)
popd

:package
echo [2/2] Installateur Dismessage %VERSION%...
"%ISCC%" /Q "/DAppVersion=%VERSION%" "/DCrtDir=%CRT%" "%ROOT%installer\dismessage.iss"
if errorlevel 1 (echo [ERREUR] Inno Setup a echoue. & goto fail)
echo.
echo Pret : %ROOT%dist\Dismessage-Setup.exe
goto end

:fail
echo.
pause
exit /b 1

:end
endlocal
