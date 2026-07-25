#!/usr/bin/env bash
set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 실패 추적 배열
FAILURES=()
GIT_IDENTITY_SETUP_ENABLED=true
BACKUP_DIR=""
BASHRC_BACKED_UP=false

record_failure() {
  echo "[-] $1"
  FAILURES+=("$1")
}

download_file() {
  local url="$1"
  local destination="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$destination"
  else
    echo "[-] curl 또는 wget이 필요합니다."
    return 1
  fi
}

backup_file() {
  local path="$1"

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi

  if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$HOME/.bootstrap-backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
  fi

  if [ -L "$path" ]; then
    cp -L -p "$path" "$BACKUP_DIR/$(basename "$path").contents"
    readlink "$path" > "$BACKUP_DIR/$(basename "$path").symlink-target"
    echo "[+] 기존 symlink 파일 백업: $BACKUP_DIR/$(basename "$path").contents"
  else
    cp -a "$path" "$BACKUP_DIR/$(basename "$path")"
    echo "[+] 기존 파일 백업: $BACKUP_DIR/$(basename "$path")"
  fi
}

deploy_config_file() {
  local source="$1"
  local destination="$2"
  local mode="$3"

  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if cmp -s "$source" "$destination"; then
      chmod "$mode" "$destination"
      echo "[=] 기존 설정 유지: $destination"
      return 0
    fi
    backup_file "$destination"
  fi

  cp -f "$source" "$destination"
  chmod "$mode" "$destination"
  echo "[+] 설정 적용: $destination"
}

configure_github_credential_store() {
  # 다른 host의 credential helper는 유지하고 GitHub에만 store를 사용한다.
  git config --global --replace-all credential.https://github.com.helper ""
  git config --global --add credential.https://github.com.helper store
}

# ============================================================
# 환경 감지 (K8s vs SSH)
# ============================================================
IS_K8S=false
if [ -n "${KUBERNETES_SERVICE_HOST:-}" ] || [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
  IS_K8S=true
  echo "[*] 쿠버네티스 환경 감지됨"
else
  echo "[*] 일반 SSH 환경 감지됨"
fi

# ============================================================
# 1. Miniconda 설치
# ============================================================
echo ""
echo "======= Miniconda 설치 ======="
echo ""

CONDA_INSTALLED=false
CONDA_EXE=""
CONDA_BASE=""

if command -v conda >/dev/null 2>&1; then
  CONDA_EXE="$(command -v conda)"
  echo "[=] Conda 이미 설치됨: $CONDA_EXE"

elif [ -x "$HOME/miniconda3/bin/conda" ]; then
  CONDA_EXE="$HOME/miniconda3/bin/conda"
  echo "[=] Miniconda 설치 재사용: $HOME/miniconda3"

else
  case "$(uname -m)" in
    x86_64|amd64) MINICONDA_ARCH="x86_64" ;;
    aarch64|arm64) MINICONDA_ARCH="aarch64" ;;
    *) MINICONDA_ARCH="" ;;
  esac

  if [ -z "$MINICONDA_ARCH" ]; then
    record_failure "지원하지 않는 CPU 아키텍처: $(uname -m)"
  else
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${MINICONDA_ARCH}.sh"
    MINICONDA_INSTALLER="$(mktemp "${TMPDIR:-/tmp}/miniconda.XXXXXX.sh")"

    if [ -d "$HOME/miniconda3" ]; then
      echo "[*] 기존 Miniconda 설치 복구/업데이트 중..."
      MINICONDA_ARGS=(-b -u -p "$HOME/miniconda3")
    else
      echo "[*] Miniconda 설치 중..."
      MINICONDA_ARGS=(-b -p "$HOME/miniconda3")
    fi

    if download_file "$MINICONDA_URL" "$MINICONDA_INSTALLER"; then
      if ! bash "$MINICONDA_INSTALLER" "${MINICONDA_ARGS[@]}"; then
        record_failure "Miniconda 설치"
      fi
    else
      record_failure "Miniconda 다운로드"
    fi
    rm -f "$MINICONDA_INSTALLER"

    if [ -x "$HOME/miniconda3/bin/conda" ]; then
      CONDA_EXE="$HOME/miniconda3/bin/conda"
      echo "[+] Miniconda 설치 확인 완료"
    fi
  fi
fi

# 현재 shell에서 conda 사용 가능하도록 초기화
if [ -n "$CONDA_EXE" ]; then
  CONDA_BASE="$("$CONDA_EXE" info --base 2>/dev/null || true)"

  if [ -n "$CONDA_BASE" ] && [ -f "$CONDA_BASE/etc/profile.d/conda.sh" ]; then
    CONDA_EXE="$CONDA_BASE/bin/conda"
    export PATH="$CONDA_BASE/bin:$PATH"
    source "$CONDA_BASE/etc/profile.d/conda.sh"
    conda activate base || record_failure "Conda base 환경 활성화"
    "$CONDA_EXE" config --set changeps1 false || true
    CONDA_INSTALLED=true
    echo "[+] 현재 shell에서 conda 활성화 완료"
  else
    record_failure "Conda 설치 경로 확인"
  fi

  if [ "$CONDA_INSTALLED" = true ] && ! grep -q 'conda initialize' "$HOME/.bashrc" 2>/dev/null; then
    if [ -s "$HOME/.bashrc" ] || [ -L "$HOME/.bashrc" ]; then
      backup_file "$HOME/.bashrc"
      BASHRC_BACKED_UP=true
    fi
    if "$CONDA_EXE" init bash >/dev/null; then
      echo "[+] conda init 완료"
    else
      echo "[!] conda init 실패 - 현재 setup은 계속 진행합니다."
    fi
  fi
elif [ "$CONDA_INSTALLED" = false ]; then
  record_failure "Miniconda 설치 확인"
fi

# ============================================================
# 2. GitHub 인증 설정 및 확인
# ============================================================
echo ""
if [ "$IS_K8S" = true ]; then
  echo "======= GitHub 인증 설정 (K8s: HTTPS Token 방식) ======="
  echo ""

  CRED_FILE="$HOME/.git-credentials"
  GITHUB_AUTH_OK=false

  # 1. 명시적으로 전달된 토큰이 없을 때만 기존 credential 재사용
  if [ -z "${GITHUB_TOKEN:-}" ] && [ -f "$CRED_FILE" ] && grep -q "github.com" "$CRED_FILE" 2>/dev/null; then
    echo "[=] 기존 ~/.git-credentials에서 GitHub 인증 정보 발견"
    configure_github_credential_store
    GITHUB_AUTH_OK=true
  fi

  # 2. 저장된 credential이 없고, 환경변수도 없으면 입력받기
  if [ "$GITHUB_AUTH_OK" = false ] && [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "[!] 쿠버네티스 환경에서는 GitHub Personal Access Token(PAT)이 필요합니다."
    echo ""
    echo "다음 페이지에서 토큰을 발급하세요:"
    echo "  https://github.com/settings/personal-access-tokens"
    echo ""
    echo "권장 권한:"
    echo "  - Contents: Read and write"
    echo "  - Metadata: Read"
    echo ""
    if [ -t 0 ]; then
      read -r -s -p "GITHUB_TOKEN을 붙여넣고 Enter (건너뛰려면 그냥 Enter): " GITHUB_TOKEN || true
      echo ""
    else
      echo "[!] 비대화형 실행이라 토큰 입력을 건너뜁니다. GITHUB_TOKEN 환경변수를 사용하세요."
    fi

    if [ -n "${GITHUB_TOKEN:-}" ]; then
      export GITHUB_TOKEN
      echo "[+] GITHUB_TOKEN 입력 완료"
    fi
  fi

  # 3. 환경변수로 토큰이 있으면 저장
  if [ "$GITHUB_AUTH_OK" = false ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    configure_github_credential_store
    if (
      umask 077
      printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=%s\n\n' "$GITHUB_TOKEN" | git credential approve
    ); then
      [ ! -f "$CRED_FILE" ] || chmod 600 "$CRED_FILE"
      echo "[+] GITHUB_TOKEN 저장 완료 (기존 다른 credential은 유지)"
      GITHUB_AUTH_OK=true
    else
      record_failure "GitHub HTTPS credential 저장"
    fi
  fi

  # 4. git remote가 git@github.com:... 여도 HTTPS로 자동 변환되게 설정
  git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
  git config --global url."https://github.com/".insteadOf "git@github.com:"
  git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"

  echo ""
  echo "======= GitHub HTTPS credential 확인 (K8s) ======="
  echo ""

  if [ "$GITHUB_AUTH_OK" = true ]; then
    echo "[+] GitHub HTTPS credential 설정 완료"
    echo "[=] 실제 저장소 권한은 첫 fetch/push 때 확인됩니다."
  else
    echo "[-] GitHub 토큰이 없어 HTTPS 인증 설정을 건너뜀"
    GIT_IDENTITY_SETUP_ENABLED=false
  fi

else
  echo "======= SSH 키 생성 및 설정 ======="
  echo ""

  SSH_DIR="$HOME/.ssh"
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"

  # SSH 키 생성 (없을 때만)
  if [ ! -f "$SSH_DIR/id_ed25519" ]; then
    SSH_KEY_COMMENT="${HOSTNAME:-$(hostname)}-$(date +%F)"
    ssh-keygen -t ed25519 -N "" -f "$SSH_DIR/id_ed25519" -C "$SSH_KEY_COMMENT"
    echo "[+] SSH 키 생성: $SSH_DIR/id_ed25519"
  else
    echo "[=] SSH 키 재사용: $SSH_DIR/id_ed25519"
  fi

  # .ssh/config 설정 (기존 설정에 추가)
  touch "$SSH_DIR/config"
  chmod 600 "$SSH_DIR/config"

  # GitHub 설정이 없으면 추가
  if ! grep -q "^Host github.com" "$SSH_DIR/config" 2>/dev/null; then
    cat >> "$SSH_DIR/config" <<EOF

Host github.com
  HostName github.com
  User git
  IdentityFile ${SSH_DIR}/id_ed25519
  IdentitiesOnly yes
EOF
    echo "[+] .ssh/config에 GitHub 설정 추가"
  else
    echo "[=] .ssh/config에 이미 GitHub 설정 존재"
  fi

  # known_hosts 설정
  touch "$SSH_DIR/known_hosts"
  if command -v ssh-keyscan >/dev/null 2>&1; then
    if ! ssh-keygen -F github.com >/dev/null 2>&1; then
      ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
    fi
  fi
  chmod 600 "$SSH_DIR/known_hosts" || true

  echo ""
  echo "======= GitHub SSH 키 등록 확인 ======="
  echo ""

  set +e
  out="$(ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_DIR/id_ed25519" -T git@github.com 2>&1)"
  set -e

  if echo "$out" | grep -qi "you've successfully authenticated"; then
    echo "[+] GitHub SSH 인증 완료"
  else
    echo "GitHub SSH 인증 필요"
    echo ""
    echo "아래 공개키를 GitHub에 등록하세요:"
    echo "----------------------------------------------------------------"
    cat "$SSH_DIR/id_ed25519.pub"
    echo "----------------------------------------------------------------"
    echo ""
    echo "등록 페이지: https://github.com/settings/keys"
    echo ""
    ans="skip"
    if [ -t 0 ]; then
      read -r -p "[?] 등록 완료 후 Enter를 누르세요 (건너뛰려면 skip): " ans || true
    else
      echo "[!] 비대화형 실행이라 SSH 인증 재확인을 건너뜁니다."
    fi
    if [ "${ans:-}" != "skip" ]; then
      set +e
      out="$(ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_DIR/id_ed25519" -T git@github.com 2>&1)"
      set -e
      if echo "$out" | grep -qi "you've successfully authenticated"; then
        echo "✅ GitHub SSH 인증 확인 완료"
      else
        echo "❌ 인증되지 않음 - 나중에 다시 확인하세요"
      fi
    fi
  fi
fi


# ============================================================
# 3. 개발 도구 설치
# ============================================================
echo ""
echo "======= 개발 도구 설치 ======="
echo ""

# conda 사용 가능한지 확인 (절대 경로를 사용해 첫 설치에서도 동작)
if [ "$CONDA_INSTALLED" != true ]; then
  record_failure "Conda 미설치로 개발 도구 설치 건너뜀"
else
  # conda Terms of Service 자동 수락 (기본 채널 사용 시 필요)
  if ! "$CONDA_EXE" tos status 2>/dev/null | grep -q "accepted"; then
    "$CONDA_EXE" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
    "$CONDA_EXE" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true
  fi

# 필요한 패키지 설치 (conda-forge 채널 사용)
install_tool() {
  local cmd="$1"
  local pkg="${2:-$1}"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "  - $pkg 설치 중..."
    if ! "$CONDA_EXE" install -y -c conda-forge "$pkg"; then
      record_failure "$pkg 설치"
    fi
  fi
}

install_tool curl
install_tool wget
install_tool git
install_tool git-lfs
install_tool tree
install_tool htop
install_tool tmux "tmux=3.5a"  # 3.6 버전 오류 회피 위해 3.5a로 고정

  # git-lfs 초기화
  if command -v git-lfs >/dev/null 2>&1; then
    if ! git lfs install 2>/dev/null; then
      FAILURES+=("git-lfs 초기화")
    fi
  fi
fi

# ============================================================
# 4. Git 기본 설정
# ============================================================
echo ""
echo "======= Git 기본 설정 ======="
echo ""

if command -v git >/dev/null 2>&1; then
  if [ "$GIT_IDENTITY_SETUP_ENABLED" = true ]; then
    current_name="$(git config --global user.name || true)"
    current_email="$(git config --global user.email || true)"

    if [ -n "$current_name" ]; then
      echo "[=] 기존 Git user.name 재사용: $current_name"
    else
      git_name=""
      if [ -t 0 ]; then
        read -r -p "Git user.name 입력 (예: Your Name): " git_name || true
      fi
      if [ -n "${git_name:-}" ]; then
        git config --global user.name "$git_name"
        echo "[+] Git user.name 설정 완료"
      else
        echo "[!] Git user.name 입력을 건너뜀"
        FAILURES+=("Git user.name 미설정")
      fi
    fi

    if [ -n "$current_email" ]; then
      echo "[=] 기존 Git user.email 재사용: $current_email"
    else
      git_email=""
      if [ -t 0 ]; then
        read -r -p "Git user.email 입력 (GitHub 연동 원하면 GitHub 계정 이메일): " git_email || true
      fi
      if [ -n "${git_email:-}" ]; then
        git config --global user.email "$git_email"
        echo "[+] Git user.email 설정 완료"
      else
        echo "[!] Git user.email 입력을 건너뜀"
        FAILURES+=("Git user.email 미설정")
      fi
    fi

    git config --global init.defaultBranch main
    git config --global pull.ff only
  else
    echo "[=] GitHub 토큰이 없어 Git 기본 설정을 건너뜀"
  fi
else
  echo "[-] git 명령을 찾을 수 없어 Git 기본 설정을 건너뜀"
  FAILURES+=("Git 기본 설정")
fi

# ============================================================
# 5. 설정 파일 복사
# ============================================================
echo ""
echo "======= 설정 파일 복사 ======="
echo ""

# .gitignore_global 복사 및 Git에 global gitignore 설정
deploy_config_file "$SCRIPT_DIR/config/.gitignore_global" "$HOME/.gitignore_global" 600

if command -v git >/dev/null 2>&1; then
  git config --global core.excludesfile "$HOME/.gitignore_global"
  echo "[+] Git global excludesfile 설정 완료"
else
  record_failure "Git global excludesfile 설정"
fi

# .tmux.conf 복사
deploy_config_file "$SCRIPT_DIR/config/.tmux.conf" "$HOME/.tmux.conf" 600

# SSH 로그인 Bash에서도 ~/.bashrc를 읽도록 설정
deploy_config_file "$SCRIPT_DIR/config/.bash_profile" "$HOME/.bash_profile" 600

# .bashrc 설정을 ~/.bashrc에 추가 (idempotent)
BASHRC="$HOME/.bashrc"
touch "$BASHRC"
BASHRC_TMP="$(mktemp "${BASHRC}.bootstrap.XXXXXX")"
START_COUNT="$(grep -Fxc "# >>> bootstrap settings >>>" "$BASHRC" 2>/dev/null || true)"
END_COUNT="$(grep -Fxc "# <<< bootstrap settings <<<" "$BASHRC" 2>/dev/null || true)"
MARKERS_VALID=true

if [ "$START_COUNT" -eq 1 ] && [ "$END_COUNT" -eq 1 ]; then
  START_LINE="$(grep -Fnx "# >>> bootstrap settings >>>" "$BASHRC" | cut -d: -f1)"
  END_LINE="$(grep -Fnx "# <<< bootstrap settings <<<" "$BASHRC" | cut -d: -f1)"
  if [ "$START_LINE" -ge "$END_LINE" ]; then
    MARKERS_VALID=false
  fi
elif [ "$START_COUNT" -ne 0 ] || [ "$END_COUNT" -ne 0 ]; then
  MARKERS_VALID=false
fi

if [ "$MARKERS_VALID" = false ]; then
  rm -f "$BASHRC_TMP"
  record_failure ".bashrc bootstrap marker가 불완전하여 수정하지 않음"
else
  if [ "$START_COUNT" -eq 1 ]; then
    sed '/^# >>> bootstrap settings >>>$/,/^# <<< bootstrap settings <<<$/{d;}' "$BASHRC" > "$BASHRC_TMP"
  else
    cp "$BASHRC" "$BASHRC_TMP"
  fi

  # 기존 마지막 줄에 개행이 없어도 bootstrap marker와 합쳐지지 않게 한다.
  if [ -s "$BASHRC_TMP" ] && [ "$(tail -c 1 "$BASHRC_TMP" | wc -l | tr -d ' ')" -eq 0 ]; then
    echo "" >> "$BASHRC_TMP"
  fi

  {
    echo "# >>> bootstrap settings >>>"
    cat "$SCRIPT_DIR/config/.bashrc"
    echo "# <<< bootstrap settings <<<"
  } >> "$BASHRC_TMP"

  if cmp -s "$BASHRC_TMP" "$BASHRC"; then
    echo "[=] 기존 .bashrc bootstrap 설정 유지"
  else
    if [ "$BASHRC_BACKED_UP" = false ] && { [ -s "$BASHRC" ] || [ -L "$BASHRC" ]; }; then
      backup_file "$BASHRC"
      BASHRC_BACKED_UP=true
    fi
    cp "$BASHRC_TMP" "$BASHRC"
    echo "[+] .bashrc bootstrap 설정 적용 완료"
  fi
  rm -f "$BASHRC_TMP"
fi

echo "[=] 새 설정은 'exec bash' 후 적용됩니다."

# ============================================================
# 6. 완료
# ============================================================
echo ""
if [ ${#FAILURES[@]} -eq 0 ]; then
  echo "✅ SETUP 완료!"
else
  echo "⚠️  SETUP 완료 (일부 실패)"
  echo ""
  echo "실패한 항목:"
  for failure in "${FAILURES[@]}"; do
    echo "  ❌ $failure"
  done
  echo ""
  exit 1
fi
echo ""

# exec bash
