; Inno Setup Installer for ChargeDose

#define MyAppName "ChargeDose"
#define MyAppVersion "2.0"
#define MyAppPublisher "Infinity Minds Inc."
#define MyAppURL "https://chargedose.whatsthetime.online"
#define MyAppExeName "ChargeDose.exe"

[Setup]
AppId={{B04FDFCE-1582-418D-B7C1-06BCD825E28A}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
AllowNoIcons=yes
LicenseFile=E:\K75 Programming\ChargeDose\license.txt
InfoBeforeFile=E:\K75 Programming\ChargeDose\readme.txt
InfoAfterFile=E:\K75 Programming\ChargeDose\readme.txt
PrivilegesRequiredOverridesAllowed=dialog
OutputBaseFilename=ChargeDoseSetup
SetupIconFile=E:\K75 Programming\ChargeDose\chargedose.ico
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "Launch {#MyAppName} at Windows startup"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "E:\K75 Programming\ChargeDose\dist\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "E:\K75 Programming\ChargeDose\chargedose.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "E:\K75 Programming\ChargeDose\chargedose.wav"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:ProgramOnTheWeb,{#MyAppName}}"; Filename: "{#MyAppURL}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; Add to run at startup if user selected the task
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "{#MyAppName}"; \
    ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
