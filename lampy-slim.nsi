; Lampy-Setup.nsi — wraps the WSL distro tarball + install.ps1 into Lampy-Setup.exe
; Build with: makensis /DOUTDIR="C:\Lampy\installer-build" lampy.nsi

!include "LogicLib.nsh"
!include "WinMessages.nsh"

!define PRODUCT_NAME "Lampy"
!define PRODUCT_VERSION "1.0.0"

Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "${OUTDIR}\Lampy-Setup.exe"
InstallDir "$LOCALAPPDATA\Lampy"
RequestExecutionLevel user
ShowInstDetails show

; Allow Cancel during install - user can abort if needed
Function .onInit
  ; Enable the X (close) button - NSIS disables it during install by default
  System::Call 'user32::GetSystemMenu(i $HWNDPARENT, i 0) i.r0'
  System::Call 'user32::EnableMenuItem(i r0, i 0xF060, i 0x0)'  ; SC_CLOSE=0xF060, MF_ENABLED=0
FunctionEnd

Function .onUserAbort
  MessageBox MB_YESNO|MB_ICONQUESTION "Cancel the Lampy installation?$\n$\nPartial files will be left in $INSTDIR." IDYES doAbort
  Abort  ; User said No, don't abort
  doAbort:
    ; Try to kill any running installer PowerShell processes
    nsExec::Exec 'taskkill /F /FI "IMAGENAME eq powershell.exe" /FI "WINDOWTITLE eq *install.ps1*"'
    Pop $0
    Abort  ; Actually abort the installation
FunctionEnd

; CheckChunk SUFFIX SIZE NUM
; Inventory one chunk in the fixed download folder ($5):
;   complete (size matches) -> skip; missing -> download fresh with progress bar;
;   partial -> leave alone, install.ps1 resumes it with HTTP Range and verifies
;   every chunk by size and SHA256 before use.
!macro CheckChunk SUFFIX SIZE NUM
  DetailPrint "Chunk ${NUM}/7: part-${SUFFIX}..."
  ${If} ${FileExists} "$5\lampy-public.tar.part-${SUFFIX}"
    FileOpen $7 "$5\lampy-public.tar.part-${SUFFIX}" r
    FileSeek $7 0 END $8
    FileClose $7
    ${If} $8 == ${SIZE}
      DetailPrint "  already complete, skipping."
    ${Else}
      DetailPrint "  partial download found - will resume during setup."
    ${EndIf}
  ${Else}
    DetailPrint "  downloading..."
    inetc::get /CAPTION "Downloading Lampy (${NUM}/7)" "$1/lampy-public.tar.part-${SUFFIX}" "$5\lampy-public.tar.part-${SUFFIX}" /END
    Pop $0
    ${If} $0 != "OK"
      MessageBox MB_ICONSTOP "Download failed (part-${SUFFIX}: $0). Check your connection and try again."
      Abort
    ${EndIf}
  ${EndIf}
!macroend


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
  ; NOTE: Tarball NOT bundled (too large for NSIS mmap). Download chunks
  ; from GitHub Releases with progress bar, then run install.ps1 for WSL setup.
  File "${OUTDIR}\install.ps1"
  File "${OUTDIR}\uninstall.ps1"

  ; Enable Cancel button during the long install (NSIS disables it by default)
  GetDlgItem $0 $HWNDPARENT 2  ; 2 = IDCANCEL
  EnableWindow $0 1

  ; Use a FIXED download folder so re-runs find existing chunks
  StrCpy $5 "$LOCALAPPDATA\Lampy\download"
  DetailPrint "Download folder: $5"
  CreateDirectory "$5"
  
  ; Migrate from C:\Lampy\download (original installer location)
  DetailPrint "Checking C:\Lampy\download..."
  ${If} ${FileExists} "C:\Lampy\download\lampy-public.tar.part-aa"
    DetailPrint "Found chunks, migrating..."
    CopyFiles /SILENT "C:\Lampy\download\lampy-public.tar.part-*" "$5\"
  ${Else}
    DetailPrint "Not found in C:\Lampy\download"
  ${EndIf}

  ; Download the 7 tarball chunks with progress bar (inetc plugin)
  ; Release v1.0.0: lampy-public.tar.part-aa through part-ag (~10.6 GB total)
  ; Using fixed $5 download folder (not $INSTDIR) so re-runs reuse chunks
  ; If the collated tarball (all 7 chunks stitched together) is already here
  ; from a previous run, skip the chunk work entirely. install.ps1 validates
  ; it by size and SHA256 before use (NSIS integers are 32-bit, so the
  ; 10.7 GB size check lives there, not here).
  ${If} ${FileExists} "$5\\lampy-public.tar"
    DetailPrint "Collated tarball already present - skipping chunk downloads."
    Goto tarball_ready
  ${EndIf}

  DetailPrint "Checking for already-downloaded chunks..."
  StrCpy $1 "https://github.com/cosbykit-afk/lampy-installer/releases/download/v1.0.0"

  ; NOTE on resume: inetc's /RESUME flag does NOT resume a partial file from a
  ; previous run - it only offers a retry dialog when a transfer errors out.
  ; So the installer inventories chunks itself: complete chunks are skipped,
  ; missing chunks download fresh with the progress bar, and PARTIAL chunks are
  ; left for install.ps1, which resumes them with HTTP Range and then verifies
  ; every chunk by size and SHA256 before use.
  ; Expected sizes for release v1.0.0 (keep in sync with the URLs above).
  !insertmacro CheckChunk "aa" "1887436800" "1"
  !insertmacro CheckChunk "ab" "1887436800" "2"
  !insertmacro CheckChunk "ac" "1887436800" "3"
  !insertmacro CheckChunk "ad" "1887436800" "4"
  !insertmacro CheckChunk "ae" "1887436800" "5"
  !insertmacro CheckChunk "af" "1887436800" "6"
  !insertmacro CheckChunk "ag" "228433920" "7"

  tarball_ready:
  DetailPrint "Chunks ready. Setting up WSL..."
  
  ; Run the installer logic (as the current user, so WSL registers for them)
  ; Chunks are in the fixed $5 download folder; pass it to install.ps1
  nsExec::ExecToLog 'powershell -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\install.ps1" -InstallDir "$INSTDIR" -DownloadDir "$5" -InstallMode "$4"'
  Pop $0
  
  ; Disable Cancel again when done
  EnableWindow $0 0
  
  ${If} $0 != "0"
    MessageBox MB_ICONSTOP "Lampy installation failed (exit $0). See details above."
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
