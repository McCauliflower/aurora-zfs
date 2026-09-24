# aurora-zfs

Aurora, rebuilt nightly with ZFS added back.

Aurora drops ZFS at Fedora 45. This image takes stock `ghcr.io/ublue-os/aurora:stable`
and reinstalls Universal Blue's matched kernel + ZFS module pair on top. It does not
patch a kernel — it installs the same pair Aurora's own build scripts install today.

## How updates work

    ublue builds aurora:stable  ->  this repo adds ZFS  ->  the machine pulls it

GitHub Actions rebuilds nightly (10:05 UTC), verifies the upstream base image
signature, builds, pushes to `ghcr.io/mccauliflower/aurora-zfs:stable`, and signs
the result. The machine's existing auto-update pulls it on its normal schedule.

Steady-state effort: none.

## The twice-a-year bump

When Aurora's stable stream moves to the next Fedora release, change
`FEDORA_VERSION` in the `Containerfile` and commit.

If you miss it, `build_files/zfs.sh` compares the base image's `VERSION_ID`
against `FEDORA_VERSION` and **aborts before publishing anything**. The machine
keeps running the last good image. Failure is loud and safe, never silent.

`zfs.sh` also aborts if `akmods-zfs` has no module built for the kernel in the
akmods image, and realigns the base kernel to that one if they differ, so the
kernel and the module are always a matched pair.

## Signing and verification

Signing uses a cosign key pair. The private half is the `SIGNING_SECRET` repo
secret; the public half belongs on the machine at
`/etc/pki/containers/aurora-zfs.pub`.

    cosign generate-key-pair

`policy-fragment.json` is the scope to merge into `/etc/containers/policy.json`.
Policy scopes match most-specific-first, so this entry takes precedence over the
`""` -> `insecureAcceptAnything` fallback that would otherwise accept this image
with no verification at all.

Without it a rebase still reports `ostree-image-signed:` while verifying nothing.

**Verify rejection before trusting it.** Push an unsigned tag and confirm the pull
is refused:

    podman pull ghcr.io/mccauliflower/aurora-zfs:unsigned-test

## Rebase

    sudo rpm-ostree rebase \
      ostree-image-signed:docker://ghcr.io/mccauliflower/aurora-zfs:stable

The `ostree-image-signed:` prefix is the signature enforcement. rpm-ostree is used
rather than `bootc switch` because rpm-ostree owns the local package layering on this
machine and `uupd` is registered as its updates driver; layered packages and base
removals carry across the rebase untouched.

Roll back with `sudo bootc rollback` and reboot.

## Local test build

    podman build -t localhost/aurora-zfs:test .

## Layered packages

Deliberately none. This image adds ZFS and nothing else.

Everyday packages (clamav, nmap, ...) stay layered locally with `rpm-ostree install`,
which keeps working after the rebase and carries across it. Keeping them out of the
image means a broken package can never take down the nightly build, and a dead build
means the machine silently stops receiving security updates.

Kernel modules are the exception — those must be in the image. Universal Blue
pre-builds several in the same akmods image already pulled here (`v4l2loopback`,
`xone`, `xpadneo`, `openrazer`, `vhba`, `wl`, `framework-laptop`); adding one means
extending the install list in `build_files/zfs.sh`.

The base-package removals on the current deployment (`kde-connect`, `krunner-bazaar`,
`kate-krunner-plugin`) are local rpm-ostree state and carry across the rebase too.

## Monitoring

`check-os-freshness.sh` answers one question daily: is the running image too old?
It does not care *why* — a dead build, a failed push, a broken `uupd`, a rejected
signature and an unresolvable layered package all look the same from here.

Checks the booted image age, `uupd.service` result, and the age of the image in the
registry. Warns at 5 days, critical at 10. Desktop notification plus a journal entry
tagged `os-freshness`. Exits 1 on warning, 2 on critical. If the check itself cannot
determine the remote age, that is treated as critical rather than passing silently.

    cp check-os-freshness.sh ~/Documents/server/custom-scripts/
    cp systemd/os-freshness.* ~/.config/systemd/user/
    systemctl --user enable --now os-freshness.timer

## Verifying the chain back to ublue

Your signature only proves you built the image — not what you built it from. The
build records the base image digest as a label, and `verify-image-chain.sh` checks
both halves: that the image is signed by your key, and that the recorded base digest
is signed by ublue's key.

`policy.json` cannot do this. A signature binds to one digest in one repository, so
ublue's signature can never appear on a derived image.

The script needs no privileges and **refuses to run as root**, because it parses JSON
fetched from a remote registry. It is installed root-owned in `/usr/local/bin` so that
nothing running as the user can modify it — note that a root-owned file in a
user-owned directory is still replaceable, since directory write permission allows
unlink and rename. The directory ownership is what matters.

It also verifies its own toolchain is root-owned and not user-writable before
proceeding. A brew-installed `cosign` does not qualify: `~/.linuxbrew/bin` is
user-writable, so cosign could be swapped for a stub that always exits 0.

    sudo ./install-root.sh
    cp systemd/*.timer systemd/*.service ~/.config/systemd/user/
    systemctl --user enable --now os-freshness.timer image-chain.timer
