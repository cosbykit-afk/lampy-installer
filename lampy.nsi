; Lampy-Setup.nsi — wraps the WSL distro tarball + install.ps1 into Lampy-Setup.exe
; Build with: makensis /DOUTDIR="C:\Lampy\installer-build" lampy.nsi

!define PRODUCT_NAME "Lampy"
!define PRODUCT_VERSION "1.0.0"

Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "${OUTDIR}\Lampy-Setup.exe"
InstallDir "C:\Lampy"
RequestExecutionLevel admin
ShowInstDetails show

Section "Install"
  SetOutPath "$INSTDIR"
  ; The tarball is large (~30GB); NSIS handles it as a single file payload
  File "${OUTDIR}\lampy-wsl.tar"
  File "${OUTDIR}\install.ps1"
  File "${OUTDIR}\uninstall.ps1"

  ; Run the installer logic elevated
  nsExec::ExecToLog 'powershell -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\install.ps1" -InstallDir "$INSTDIR"'
  Pop $0
  ${If} $0 != "0"
    MessageBox MB_ICONSTOP "Lampy installation failed (exit $0). See details above."
    Abort
  ${EndIf}

  ; Start Menu shortcuts
  CreateDirectory "$SMPROGRAMS\Lampy"
  CreateShortcut "$SMPROGRAMS\Lampy\Forum.lnk" "http://localhost/app/"
  CreateShortcut "$SMPROGRAMS\Lampy\R Theory.lnk" "http://localhost/r-theory/"
  CreateShortcut "$SMPROGRAMS\Lampy\Uninstall.lnk" \
    'powershell' '-NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\uninstall.ps1"'

  ; Registry uninstall entry
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Lampy" \
    "DisplayName" "${PRODUCT_NAME} ${PRODUCT_VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Lampy" \
    "UninstallString" 'powershell -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\uninstall.ps1"'
SectionEnd
