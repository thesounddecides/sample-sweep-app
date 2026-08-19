; Sample Sweep - Windows installer (Inno Setup 6)
;
;   ISCC.exe /DMyAppVersion=1.0.2 windows\installer.iss
;
; Produces windows\build\SampleSweep-Setup-<version>.exe from the PyInstaller
; one-folder build in windows\build\dist\Sample Sweep\.
;
; Per-user install by default (no UAC prompt, lands in %LOCALAPPDATA%\Programs),
; which is what a free tool for non-technical producers wants. Signing is wired
; through the optional SignTool define so the same script works unsigned today
; and signed once Azure Trusted Signing is set up (see windows/README.md).

#define MyAppName "Sample Sweep"
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#define MyAppPublisher "Sound Decisions LLC"
#define MyAppURL "https://thesounddecides.com/sample-sweep"
#define MyAppExeName "Sample Sweep.exe"
#define MyDist "build\dist\Sample Sweep"

[Setup]
; Never change AppId: it is how Windows knows a newer installer upgrades this app.
AppId={{6E3CF45A-2200-4470-9402-37624567F7E4}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableWelcomePage=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; x64compatible needs Inno Setup 6.3+ (the GitHub runner ships newer). On an
; older ISCC, use "x64" instead.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=build
OutputBaseFilename=SampleSweep-Setup-{#MyAppVersion}
SetupIconFile=assets\SampleSweep.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=no
#ifdef SignTool
SignTool={#SignTool}
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#MyDist}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
