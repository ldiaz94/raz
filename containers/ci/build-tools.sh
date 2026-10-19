#!/bin/sh
set -eu

raz_version=0.21.0
raz_sha256=a8e2e550e927050d36a7e9731e6de22b094189adea15a984cd921917cbd8d90f
concha_revision=029289644abee68ddc3c06da526d394939846a41
robbie_revision=3328bcf7060ef663b309e8a7a5e8a528a7962aee
robbie_build_raz=0.18.0
robbie_build_raz_sha256=d05f2adbfddd52eabbf10db275fa69390102f46e40825ae94adaeade219799aa
rzone_revision=2644afb0827fe5ce1679a386336728183d61db11

mkdir -p /opt/raz /tmp/raz-ci /usr/local/share/raz-ci
cd /tmp/raz-ci
curl --fail --location --retry 3 \
    "https://raz.lucelad.workers.dev/download/raz-$raz_version-linux-x86_64.tar.gz" \
    -o raz.tar.gz
printf '%s  raz.tar.gz\n' "$raz_sha256" | sha256sum -c -
tar -xzf raz.tar.gz --strip-components=1 -C /opt/raz
export PATH="/opt/raz:$PATH"
raz --version | grep '^raz 0\.21\.0, '

fetch() {
    git init -q "$1"
    git -C "$1" remote add origin "https://github.com/ldiaz94/$1.git"
    attempt=1
    until git -C "$1" fetch -q --depth=1 origin "$2"; do
        if [ "$attempt" -ge 3 ]; then return 1; fi
        attempt=$((attempt + 1))
        sleep 2
    done
    git -C "$1" checkout -q --detach FETCH_HEAD
    test "$(git -C "$1" rev-parse HEAD)" = "$2"
}

fetch rzone "$rzone_revision"
fetch concha "$concha_revision"
fetch robbie "$robbie_revision"
make -C rzone check
make -C concha test
# robbie's latest commit changes RAZVERSION alone. Its source still uses
# the 0.18 library's pointer API; use that compiler only in this build stage.
curl --fail --location --retry 3 \
    "https://raz.lucelad.workers.dev/download/raz-$robbie_build_raz-linux-x86_64.tar.gz" \
    -o robbie-raz.tar.gz
printf '%s  robbie-raz.tar.gz\n' "$robbie_build_raz_sha256" | sha256sum -c -
mkdir robbie-raz
tar -xzf robbie-raz.tar.gz --strip-components=1 -C robbie-raz
robbie_raz="$PWD/robbie-raz/raz"
"$robbie_raz" --version | grep '^raz 0\.18\.0, '
make -C robbie test RAZ="$robbie_raz" RAZVERSION="$robbie_build_raz"
make -C concha install PREFIX=/usr/local
make -C robbie install PREFIX=/usr/local RAZ="$robbie_raz" RAZVERSION="$robbie_build_raz"

cat > /usr/local/share/raz-ci/versions.txt <<EOF
image=0.21.0-debian12-r1
raz=$raz_version
raz_archive_sha256=$raz_sha256
concha=$concha_revision
robbie=$robbie_revision
robbie_build_raz=$robbie_build_raz
robbie_build_raz_archive_sha256=$robbie_build_raz_sha256
rzone=$rzone_revision
EOF
dpkg-query -W > /usr/local/share/raz-ci/packages.txt
for project in concha robbie rzone; do
    if [ -f "$project/LICENSE" ]; then
        install -Dm644 "$project/LICENSE" "/usr/local/share/licenses/$project/LICENSE"
    fi
done
