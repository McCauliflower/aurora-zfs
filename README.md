# aurora-zfs

Messing around with Aurora + ZFS in a VM. Aurora drops ZFS support at Fedora 45,
so this just reinstalls the kernel + ZFS module pair Aurora's own build scripts
used to install, on top of stock `ghcr.io/ublue-os/aurora:stable`.

Mostly an excuse to poke at rpm-ostree, container image layering, and cosign
signing without breaking a real machine. Nothing here is meant to go anywhere
beyond a throwaway VM.

## How it's wired up

    ublue builds aurora:stable  ->  this adds ZFS  ->  test VM pulls it

A GitHub Action rebuilds nightly, checks the upstream signature, builds, pushes
to `ghcr.io/mccauliflower/aurora-zfs:stable`, and signs the result — mostly so
I can see whether the signing/verification flow actually behaves the way I
think it does.

## The twice-a-year bump

When Aurora's stable stream moves to the next Fedora release, bump
`FEDORA_VERSION` in the `Containerfile`.

`build_files/zfs.sh` checks the base image's `VERSION_ID` against
`FEDORA_VERSION` and bails before publishing if they don't match, so a missed
bump doesn't quietly ship a broken image to the VM. It also checks that
`akmods-zfs` actually has a module for the kernel in play.

## Signing (to see if it works)

    cosign generate-key-pair

`policy-fragment.json` is a scope for `/etc/containers/policy.json` on the test
VM — without it, `ostree-image-signed:` reports success without actually
checking anything.

There's an intentionally-unsigned tag to confirm the VM actually refuses it:

    podman pull ghcr.io/mccauliflower/aurora-zfs:unsigned-test

## Rebasing the test VM

    sudo rpm-ostree rebase \
      ostree-image-signed:docker://ghcr.io/mccauliflower/aurora-zfs:stable

Using rpm-ostree instead of `bootc switch` just because that's what the VM's
`uupd` setup expects.

Roll back with `sudo bootc rollback` if it goes sideways.

## Local build

    podman build -t localhost/aurora-zfs:test .

## Layered packages

None on purpose — the image is just ZFS. Everything else stays layered on the
VM with `rpm-ostree install` so a bad package can't take down the nightly
build.

Kernel modules are the exception since those have to live in the image itself.

## Some poking-around scripts

`check-os-freshness.sh` is just a cron-ish check on whether the VM's image is
stale — dead build, failed push, broken `uupd`, whatever. Same bucket either
way. Also nags when a staged update has sat unbooted for 3 days, and warns
when a published image still isn't staged or booted 36 hours later.

`verify-image-chain.sh` checks that the recorded base-image digest is actually
signed by ublue, since a signature only proves *I* signed something, not what
it was built from. Refuses to run as root on purpose — it's parsing JSON off
the network, no reason to give it more than it needs.

`systemd/image-chain.service` runs it as your user, so it has `@USER@`, `@UID@`
and `@HOME@` placeholders to fill in at install time (run from inside the
repo, as yourself, not under sudo). Every step is chained with `&&`, so if one
fails (wrong directory, no file) nothing after it runs and nothing under `/etc`
is touched:

```
top="$(git rev-parse --show-toplevel)" && cd "${top}" &&
unit="$(mktemp)" &&
sed -e "s|@USER@|$(id -un)|g" -e "s|@UID@|$(id -u)|g" -e "s|@HOME@|${HOME}|g" \
    systemd/image-chain.service > "${unit}" &&
grep -q '^User=' "${unit}" && ! grep -q '@[A-Z]\+@' "${unit}" &&
sudo install -o root -g root -m 0644 "${unit}" /etc/systemd/system/image-chain.service &&
sudo install -o root -g root -m 0644 systemd/image-chain.timer /etc/systemd/system/ &&
sudo systemctl daemon-reload
rm -f "${unit}"
```


