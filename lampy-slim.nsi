; Lampy-Setup.nsi — thin public installer wrapper (v1.1.2)
;
; Design (see Installer_Requirements.md — requirements before code):
;   - NSIS NEVER downloads. install.ps1 owns manifest discovery, chunk
;     inventory, resumable download, verification, reassembly, WSL import.
;   - The download folder is %LOCALAPPDATA%\Lampy\download and NEVER moves.
;   - install.ps1 runs in a VISIBLE console so the user watches real progress.
;   - Every run appends to install.log in the download folder.
;
; Build (Linux): sed 's|\${OUTDIR}\\|\${OUTDIR}/|g' lampy-slim.nsi > /tmp/b/lampy-slim.nsi
;   && cp install.ps1 uninstall.ps1 manifest.json wsl-envfix.py /tmp/b/
;   && python3 verify-bundle.py /tmp/b
;   && makensis -DOUTDIR=/tmp/b /tmp/b/lampy-slim.nsi
; Build (Windows): makensis /DOUTDIR="C:\Lampy\installer-build" lampy-slim.nsi

!include "LogicLib.nsh"
!include "WinMessages.nsh"

!define PRODUCT_NAME "Lampy"
!define PRODUCT_VERSION "1.1.6"

Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "${OUTDIR}\Lampy-Setup.exe"
InstallDir "$LOCALAPPDATA\Lampy"
RequestExecutionLevel user
ShowInstDetails show

; The ONE permanent download location. Locked — never change this again.
!define DOWNLOAD_DIR "$LOCALAPPDATA\Lampy\download"

Function .onInit
  ; Enable the X (close) button - NSIS disables it during install by default
  System::Call 'user32::GetSystemMenu(i $HWNDPARENT, i 0) i.r0'
  System::Call 'user32::EnableMenuItem(i r0, i 0xF060, i 0x0)'  ; SC_CLOSE=0xF060, MF_ENABLED=0
FunctionEnd

Function .onUserAbort
  MessageBox MB_YESNO|MB_ICONQUESTION "Cancel the Lampy installation?$\n$\nPartial files stay in ${DOWNLOAD_DIR} and the next run resumes them." IDYES doAbort
  Abort  ; User said No, don't abort
  doAbort:
    nsExec::Exec 'taskkill /F /FI "IMAGENAME eq powershell.exe" /FI "WINDOWTITLE eq *install.ps1*"'
    Pop $0
    Abort  ; Actually abort the installation
FunctionEnd

Section "Install"
  ; Check if Lampy is already installed (by looking for the WSL virtual disk)
  ; If found, ask user whether to reinstall, repair, or cancel
  DetailPrint "Checking for existing Lampy installation..."
  ${If} ${FileExists} "$INSTDIR\wsl\ext4.vhdx"
    MessageBox MB_YESNOCANCEL|MB_ICONQUESTION "Lampy appears to be already installed in $INSTDIR.$\n$\nYes = Reinstall (removes existing and installs fresh)$\nNo = Repair (keeps data, re-runs setup)$\nCancel = Exit installer" IDYES reinstall IDNO repair
    repair:
      DetailPrint "Repair mode: keeping existing data, re-running setup..."
      StrCpy $4 "repair"
      Goto install_continue
    reinstall:
      DetailPrint "Reinstall mode: will remove existing installation..."
      StrCpy $4 "reinstall"
      Goto install_continue
    ; Cancel falls through to Abort
    Abort
  ${EndIf}
  StrCpy $4 "fresh"

  install_continue:
  SetOutPath "$INSTDIR"
  ; Bundle the setup scripts + fallback manifest (tarball itself downloads at
  ; install time — far too large to bundle).
  File "${OUTDIR}\install.ps1"
  File "${OUTDIR}\uninstall.ps1"
  File "${OUTDIR}\manifest.json"
  File "${OUTDIR}\wsl-envfix.py"
  File "${OUTDIR}\set-passwords.py"

  ; Enable Cancel button during the long install (NSIS disables it by default)
  GetDlgItem $0 $HWNDPARENT 2  ; 2 = IDCANCEL
  EnableWindow $0 1

  ; The permanent download folder. Created once, never moved, never renamed.
  DetailPrint "Download folder: ${DOWNLOAD_DIR}"
  CreateDirectory "${DOWNLOAD_DIR}"

  ; Hand off to install.ps1 in a VISIBLE console window: the user watches
  ; honest per-chunk progress there. NSIS just waits for the exit code.
  DetailPrint "Launching setup (watch the PowerShell window for progress)..."
  ExecWait 'powershell -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\install.ps1" -InstallDir "$INSTDIR" -DownloadDir "${DOWNLOAD_DIR}" -InstallMode "$4" -FallbackManifest "$INSTDIR\manifest.json"' $0

  ; Disable Cancel again when done
  EnableWindow $0 0

  ${If} $0 != "0"
    MessageBox MB_ICONSTOP "Lampy installation failed (exit $0).$\n$\nSee the install window output and ${DOWNLOAD_DIR}\install.log for details."
    Abort
  ${EndIf}

  ; Start Menu shortcuts (per-user)
  CreateDirectory "$SMPROGRAMS\Lampy"
  CreateShortcut "$SMPROGRAMS\Lampy\Forum.lnk" "http://localhost/app/"
  CreateShortcut "$SMPROGRAMS\Lampy\R Theory.lnk" "http://localhost/r-theory/"
  CreateShortcut "$SMPROGRAMS\Lampy\Uninstall.lnk" \
    'powershell' '-NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\uninstall.ps1"'

  ; Registry uninstall entry (per-user HKCU, no admin needed)
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Lampy" \
    "DisplayName" "${PRODUCT_NAME} ${PRODUCT_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Lampy" \
    "UninstallString" 'powershell -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\uninstall.ps1"'
SectionEnd
