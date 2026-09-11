# Automated creation of an OpenBSD custom QEMU box

<p align="center">
  <img src="https://www.openbsd.org/images/PinkPuffy.png" alt="OpenBSD 7.9 artwork by Lyra Henderson" width="200">
</p>


## Additional Requirements (see root project folder)

- `curl` (for downloading installation images)
- Python 3 (for the built-in HTTP server during installation)

## Project structure

```
openbsd/                  # OpenBSD QEMU box
├── openbsd_box.sh        # Main script (setup, install, boot)
├── install.conf          # Autoinstall configuration
├── custom_disklabel.conf # Custom disk partition layout
├── site_build/           # Post-install customization scripts
├── openbsd_box.sh        # Main script (setup, install, boot)
└── README.md
```

## Quickstart
1. Modify the `openbsd_box.sh` script according to your needs. Specifically, you will
want to modify the following local variables:
    - `$RELEASE`, `$ARCH`, and `$IMAGE_NAME` = self-explanatory.
    - `$QCOW2_DISK_NAME`: defines the name of the resulting qcow2 image.
    - `$QCOW2_DISK_CAPACITY`: defines the size of the resulting qcow2 image.
    - `$SSH_PORT`: defines the local host port that will be used to connect via SSH to
      the guest host after boot up.

2. Configure OpenBSD (automatic) installation steps: `$EDITOR ./install.conf`.
    > See [autoinstall(8)](https://man.openbsd.org/autoinstall.8)

3. Configure OpenBSD partition table: `$EDITOR ./custom_disklabel.conf`.
    > Take into mind that the maximum storage available has been defined in Step 1
(via the `$QCOW2_DISK_CAPACITY` variable)!!

4. If needed, the OpenBSD installation can be further customized via the
site_build directory.
    > See [install.site(5)](https://man.openbsd.org/install.site.5)


5. Tar the site_build directory up (if applicable)
```bash
# From the repository root project
tar -czvf siteXX.tgz -C site_build .
```

**Note:** It is optional to include this file (see Step 4), but it is highly
recommended as it includes common commands used during the post-installation
process, that you likely want to preserve.

6. Install the OpenBSD box:
```bash
# 1. Serve the siteXX.tgz, install.conf, and custom_disklabel.conf files
cd "${PROJECT_ROOT}"; python3 -m http.server 80
# 2. Proceed with the installation process
chmod +x openbsd_box.sh; ./openbsd_box.sh -i
# 3. Once we have booted into the OpenBSD installation image, type
# 'Automatic (A)' to follow the automatic installation process
# 4. Next, OpenBSD will ask to retrieve files from 'http://10.0.2.2:80',
# press Enter and wait for the installation to complete
# 5. You will see that QEMU boots into the installation image again.
# That is fine, you just have to quit QEMU.

```

8. Done! Your QEMU box is ready.
```sh
# Remember to copy you public user ssh key
ssh-copy-id -i ~/.ssh/<id_rsa.pub> -p 2424 bsd@localhost
```

9. Whenever you want to boot into your VM,
execute these commands:
```bash
# Power on the VM
./openbsd_box.sh
# SSH using the same $SSH_PORT and $USERNAME values selected in previous steps
ssh -p $SSH_PORT $USERNAME@localhost
```

**Note:** Replace XX with the specified OpenBSD release number.


## DEBUGGING
*TODO*
