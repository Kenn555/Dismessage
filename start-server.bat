@echo off
setlocal
chcp 65001 >nul
title Dismessage - serveur

rem Lance le relais Dismessage (WebSocket /ws + client web) sur le port 8080.
rem Usage : double-clic, ou "start-server.bat 9000" pour un autre port.
rem   start-server.bat --rebuild   recompile le client web avant de lancer.

set "ROOT=%~dp0"
set "PORT=8080"
set "REBUILD="

:args
if "%~1"=="" goto args_done
if /i "%~1"=="--rebuild" (set "REBUILD=1") else (set "PORT=%~1")
shift
goto args
:args_done

where dart >nul 2>&1
if errorlevel 1 (
  echo [ERREUR] "dart" introuvable. Ajoutez C:\dev\flutter\bin au PATH.
  goto fail
)

rem Client web : compile s'il est absent, si --rebuild est demande, ou si le
rem code a change depuis la derniere compilation (commit different ou
rem modifications non commitees). Un client perime parle mal au serveur.
set "STAMP=%ROOT%app\build\web\.dismessage-commit"
set "HEAD="
for /f %%h in ('git -C "%ROOT%." rev-parse HEAD 2^>nul') do set "HEAD=%%h"
set "DIRTY="
if defined HEAD (
  git -C "%ROOT%." diff --quiet HEAD -- app/lib app/web app/pubspec.yaml packages/protocol/lib || set "DIRTY=1"
)
set "BUILT="
if exist "%STAMP%" set /p BUILT=<"%STAMP%"
if defined REBUILD goto build_web
if not exist "%ROOT%app\build\web\index.html" goto build_web
if defined DIRTY goto build_web
if defined HEAD if not "%BUILT%"=="%HEAD%" goto build_web
goto web_ok
:build_web
echo [1/3] Compilation du client web...
pushd "%ROOT%app"
rem Flutter garde parfois une liste de plugins web perimee dans ce cache
rem (images, micro et audio absents : MissingPluginException). On la jette.
if exist ".dart_tool\flutter_build" rmdir /s /q ".dart_tool\flutter_build"
call flutter build web --release
if errorlevel 1 (popd & echo [ERREUR] Compilation web echouee. & goto fail)
popd
if defined HEAD if not defined DIRTY (>"%STAMP%" echo %HEAD%)
:web_ok

echo [2/3] Dependances du serveur...
pushd "%ROOT%server"
call dart pub get --offline >nul 2>&1 || call dart pub get
if errorlevel 1 (popd & echo [ERREUR] dart pub get a echoue. & goto fail)

echo [3/3] Demarrage sur le port %PORT% (Ctrl+C pour arreter)
echo     Tunnel VS Code : onglet Ports, port %PORT%, visibilite Public.
echo.
set "DISMESSAGE_WEB=%ROOT%app\build\web"
dart run bin/server.dart
popd
goto end

:fail
echo.
pause
exit /b 1

:end
endlocal
