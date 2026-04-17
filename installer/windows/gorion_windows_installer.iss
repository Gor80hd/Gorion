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
  #define AppVersion "1.2.0"
#endif

#ifndef PrivilegedHelperTaskName
  #define PrivilegedHelperTaskName "Gorion Privileged Helper"
#endif

#ifndef PrivilegedHelperArg
  #define PrivilegedHelperArg "--gorion-privileged-helper"
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

[UninstallDelete]
Type: files; Name: "{app}\gorion_privileged_helper.installed"

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
function BuildPrivilegedHelperCreateScript(): String;
begin
  Result :=
    '$taskName = ''{#PrivilegedHelperTaskName}''' + #13#10 +
    '$appPath = ''' + ExpandConstant('{app}\{#AppExeName}') + '''' + #13#10 +
    '$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name' + #13#10 +
    '$action = New-ScheduledTaskAction -Execute $appPath -Argument ''{#PrivilegedHelperArg}''' + #13#10 +
    '$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId' + #13#10 +
    '$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest' + #13#10 +
    'Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null' + #13#10 +
    'Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null' + #13#10 +
    'Start-ScheduledTask -TaskName $taskName | Out-Null';
end;

function BuildPrivilegedHelperRemoveScript(): String;
begin
  Result :=
    '$taskName = ''{#PrivilegedHelperTaskName}''' + #13#10 +
    '$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue' + #13#10 +
    'if ($null -ne $task) {' + #13#10 +
    '  Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null' + #13#10 +
    '  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null' + #13#10 +
    '}';
end;

function RunPowerShellScript(const Script: String): Boolean;
var
  ScriptPath: String;
  Params: String;
  ResultCode: Integer;
begin
  ScriptPath := ExpandConstant('{tmp}\gorion_privileged_helper.ps1');
  if not SaveStringToFile(ScriptPath, Script, False) then
  begin
    Result := False;
    Exit;
  end;

  Params :=
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ScriptPath + '"';
  Result :=
    Exec(
      ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      Params,
      '',
      SW_HIDE,
      ewWaitUntilTerminated,
      ResultCode
    ) and (ResultCode = 0);
  DeleteFile(ScriptPath);
end;

procedure EnsurePrivilegedHelperMarker();
begin
  SaveStringToFile(
    ExpandConstant('{app}\gorion_privileged_helper.installed'),
    '',
    False
  );
end;

procedure RemovePrivilegedHelperMarker();
begin
  DeleteFile(ExpandConstant('{app}\gorion_privileged_helper.installed'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    RunPowerShellScript(BuildPrivilegedHelperRemoveScript());
    RemovePrivilegedHelperMarker();
  end;

  if CurStep = ssPostInstall then
  begin
    if RunPowerShellScript(BuildPrivilegedHelperCreateScript()) then
    begin
      EnsurePrivilegedHelperMarker();
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    RunPowerShellScript(BuildPrivilegedHelperRemoveScript());
    RemovePrivilegedHelperMarker();
  end;
end;
