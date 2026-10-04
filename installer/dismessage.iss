; Installateur Windows de Dismessage (Inno Setup 6).
; Ne pas compiler directement : lancer build-installer.bat (racine du dépôt),
; qui fournit la version, le dossier du runtime Visual C++ et compile l'appli.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef CrtDir
  #error "CrtDir manquant : lancer build-installer.bat"
#endif
#define AppName "Dismessage"
#define AppExe "dismessage.exe"
#define BuildDir "..\app\build\windows\x64\runner\Release"

[Setup]
; Ne jamais changer cet identifiant : il permet aux nouvelles versions de
; remplacer l'ancienne au lieu de s'installer à côté.
AppId={{30F98AB9-5878-4BA3-B41C-549E7D7B80F8}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppName}
AppComments=Messagerie où l'on voit l'interlocuteur écrire en direct.
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
; Pas besoin d'être administrateur (installation dans le profil), mais on
; peut choisir « pour tous les utilisateurs ».
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\dist
OutputBaseFilename=Dismessage-Setup
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; Ferme Dismessage s'il tourne pendant une mise à jour.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startup"; Description: "Lancer Dismessage au démarrage de Windows (réduit dans la barre des tâches, pour rester joignable)"; GroupDescription: "Démarrage :"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Runtime Visual C++ à côté de l'appli : elle démarre même si le
; « Redistribuable Visual C++ » n'est pas installé sur le PC.
Source: "{#CrtDir}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\msvcp140_1.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\msvcp140_2.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#CrtDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; Démarrage avec Windows : propre à l'utilisateur, retiré à la désinstallation
; ou si la case est décochée lors d'une réinstallation.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#AppName}"; ValueData: """{app}\{#AppExe}"" --minimized"; Flags: uninsdeletevalue; Tasks: startup
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "{#AppName}"; Flags: deletevalue; Tasks: not startup

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
