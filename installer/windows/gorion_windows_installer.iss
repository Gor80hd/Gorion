#ifndef AppName
  #define AppName "Gorion"
#endif

#ifndef AppPublisher
  #define AppPublisher "Gorion"
#endif

#ifndef AppExeName
  #define AppExeName "gorion_clean.exe"
#endif

#ifndef AppVersion
  #define AppVersion "1.0.1"
#endif

#ifndef SourceDir
  #define SourceDir "..\\..\\build\\windows\\x64\\runner\\Release"
#endif

#ifndef OutputDir
  #define OutputDir "..\\..\\dist\\windows-installer"
#endif

[Setup]
AppId={{5A6A93A8-8C74-47D7-9533-E821AC4AF4A4}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://example.com/
AppSupportURL=https://example.com/
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
LicenseFile=
PrivilegesRequired=admin
OutputDir={#OutputDir}
OutputBaseFilename={#AppName}-Setup-{#AppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#AppExeName}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
