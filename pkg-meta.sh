#!/bin/sh
# pkg-meta.sh [arch-package] [file.AppImage]
# Χωρίς όρισμα: το πακέτο βρίσκεται από το $DESKTOP (pacman -Qqo).
# Τρέχει ΜΕΣΑ στο Arch container, ΜΕΤΑ το `quick-sharun --make-appimage` (και το test).
# Μετονομάζει  Name-VER-anylinux-ARCH.AppImage -> Name-VER-ARCH.AppImage  και βάζει στο dist:
#   Name-VER-ARCH.AppImage.sha256   <pkg>-<arch>.json   <pkg>-<arch>.xml (AppStream)
#   <όνομα>.desktop (όπως είναι)   <pkg>.png|svg (icon)
set -eu

PKG=${1:-}
if [ -z "$PKG" ]; then
	PKG=$(pacman -Qqo "${DESKTOP:?set DESKTOP or pass the package name}" 2>/dev/null | head -n1) \
		|| true
	[ -n "$PKG" ] || { echo "pkg-meta: cannot detect package from DESKTOP=$DESKTOP" >&2; exit 1; }
fi
OUT=${OUTPATH:-./dist}
APPDIR=${APPDIR:-./AppDir}
ARCH=${ARCH:-$(uname -m)}
mkdir -p "$OUT"
AI=${2:-$(ls "$OUT"/*.AppImage 2>/dev/null | head -n1)}
[ -f "$AI" ] || { echo "pkg-meta: no AppImage in $OUT" >&2; exit 1; }
AIF=${AI##*/}
case "$AIF" in *-anylinux-*)   # Kate-1.0-anylinux-x86_64.AppImage -> Kate-1.0-x86_64.AppImage
	NEW=$(printf '%s' "$AIF" | sed 's/-anylinux//')
	mv -f "$AI" "${AI%/*}/$NEW"; AI=${AI%/*}/$NEW; AIF=$NEW ;;
esac

P="$PKG-$ARCH"   # σταθερό όνομα, ανεξάρτητο της έκδοσης

# --- helpers ---------------------------------------------------------------
je() { printf '%s' "$1" | tr '\n\t' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
pi() { LC_ALL=C pacman -Qi "$PKG" | sed -n "s/^$1 *: //p" | head -n1; }
jarr() { # args: λίστα αρχείων -> ["a","b"]
	out=
	for x; do out="$out${out:+,}\"$(je "${x##*/}")\""; done
	printf '[%s]' "$out"
}
dkey() { sed -n "s/^$2=//p" "$1" | head -n1; }   # non-localized key από .desktop

# --- 1. SHA256 -------------------------------------------------------------
SHA=$(sha256sum "$AI" | cut -d' ' -f1)
( cd "$OUT" && printf '%s  %s\n' "$SHA" "$AIF" > "$AIF.sha256" )
SIZE=$(stat -c %s "$AI")

# --- 2. .desktop -----------------------------------------------------------
DESKTOPS=
for f in "$APPDIR"/*.desktop "$APPDIR"/share/applications/*.desktop; do
	[ -f "$f" ] && DESKTOPS="$DESKTOPS $f"
done
[ -n "$DESKTOPS" ] || { [ -f "${DESKTOP:-}" ] && DESKTOPS=$DESKTOP; }
[ -n "$DESKTOPS" ] || echo "WARN: no .desktop found" >&2
DLIST=
for f in $DESKTOPS; do
	case " $DLIST " in *" $OUT/${f##*/} "*) continue;; esac   # ίδιο όνομα = μία φορά
	cp -f "$f" "$OUT/${f##*/}"; DLIST="$DLIST $OUT/${f##*/}"
done
MAIN=${DESKTOPS%% *}; MAIN=${MAIN# }
[ -z "$MAIN" ] && MAIN=$(echo $DESKTOPS | cut -d' ' -f1)

# --- 3. icon ---------------------------------------------------------------
# Το .DirIcon είναι συνήθως αντίγραφο (όχι symlink) και μπορεί να μην έχει κατάληξη
# (π.χ. όταν το ICON είναι URL με ?ref_type=...), οπότε ο τύπος βρίσκεται από το περιεχόμενο.
ICONF=; ICONEXT=
for f in "$APPDIR/.DirIcon" "$APPDIR"/*.png "$APPDIR"/*.svg "$APPDIR"/*.png\?* "$APPDIR"/*.svg\?*; do
	[ -s "$f" ] || continue
	if [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 89504e47 ]; then ICONEXT=png
	elif grep -q '<svg' "$f" 2>/dev/null; then ICONEXT=svg
	else continue; fi
	ICONF=$f; break
done
ICONNAME=
if [ -n "$ICONF" ]; then
	ICONNAME="$PKG.$ICONEXT"; cp -fL "$ICONF" "$OUT/$ICONNAME"
else echo "WARN: no icon found in $APPDIR" >&2; fi

# --- 4. AppStream ----------------------------------------------------------
METAS=$(pacman -Ql "$PKG" | awk '{print $2}' | grep -E '/usr/share/(metainfo|appdata)/[^/]+\.xml$' || true)
MLIST=; SEEN=
for f in $METAS; do
	case " $SEEN " in *" ${f##*/} "*) continue;; esac; SEEN="$SEEN ${f##*/}"
	if [ -z "$MLIST" ]; then dst="$OUT/$P.xml"; else dst="$OUT/${f##*/}"; fi   # πρώτο = <pkg>-<arch>.xml
	cp -f "$f" "$dst"; MLIST="$MLIST $dst"
done
MAINM=$(echo $MLIST | cut -d' ' -f1)
AS_NAME=; AS_SUM=; AS_ID=
if [ -n "$MAINM" ]; then
	AS_ID=$(sed -n 's|.*<id>\(.*\)</id>.*|\1|p' "$MAINM" | head -n1)
	AS_NAME=$(sed -n 's|^ *<name>\(.*\)</name>.*|\1|p' "$MAINM" | head -n1)
	AS_SUM=$(sed -n 's|^ *<summary>\(.*\)</summary>.*|\1|p' "$MAINM" | head -n1)
fi

# --- 5. URL (χωρίς API: κλασικά release download links) --------------------
REPO=${GITHUB_REPOSITORY:-}
if [ "${DEVEL_RELEASE-}" = 1 ]; then TAGPATH=download/nightly; else TAGPATH=latest/download; fi
BASE=
[ -n "$REPO" ] && BASE="https://github.com/$REPO/releases/$TAGPATH"

# --- 6. JSON ---------------------------------------------------------------
J="$OUT/$P.json"
cat > "$J" <<JSON
{
  "pkg": "$(je "$PKG")",
  "arch": "$(je "$ARCH")",
  "version": "$(je "$(pi Version)")",
  "description": "$(je "$(pi Description)")",
  "upstream_url": "$(je "$(pi URL)")",
  "licenses": "$(je "$(pi Licenses)")",
  "packager": "$(je "$(pi Packager)")",
  "build_date": "$(je "$(pi 'Build Date')")",
  "installed_size": "$(je "$(pi 'Installed Size')")",
  "appstream": {
    "id": "$(je "$AS_ID")",
    "name": "$(je "$AS_NAME")",
    "summary": "$(je "$AS_SUM")"
  },
  "desktop": {
    "name": "$(je "$([ -n "$MAIN" ] && dkey "$MAIN" Name)")",
    "comment": "$(je "$([ -n "$MAIN" ] && dkey "$MAIN" Comment)")",
    "categories": "$(je "$([ -n "$MAIN" ] && dkey "$MAIN" Categories)")",
    "files": $(jarr $DLIST)
  },
  "metainfo_files": $(jarr $MLIST),
  "icon": "$(je "$ICONNAME")",
  "appimage": {
    "file": "$(je "$AIF")",
    "size": $SIZE,
    "sha256": "$SHA",
    "url": "$(je "${BASE:+$BASE/}$AIF")"
  },
  "generated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
echo "pkg-meta: wrote $J"
