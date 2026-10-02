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

rem Client web : compile s'il est absent ou si --rebuild est demande.
if defined REBUILD goto build_web
if exist "%ROOT%app\build\web\index.html" goto web_ok
:build_web
echo [1/3] Compilation du client web...
pushd "%ROOT%app"
call flutter build web --release
if errorlevel 1 (popd & echo [ERREUR] Compilation web echouee. & goto fail)
popd
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
