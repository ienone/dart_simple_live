[Setup]
AppId={{409B0DD5-A627-4EB6-82E2-4D1C49D3D425}
AppName=test-Slive
AppVersion=1.0
DefaultDirName={localappdata}\Programs\test-Slive
DefaultGroupName=test-Slive
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=test-Slive-windows-x64-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\test-slive.exe
[Files]
Source: "..\simple_live_app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\test-Slive"; Filename: "{app}\test-slive.exe"
Name: "{autodesktop}\test-Slive"; Filename: "{app}\test-slive.exe"
