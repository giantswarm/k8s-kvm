/*

Copyright 2020 Salvatore Mazzarino

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

		https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package distro

import (
	"fmt"
	"net/url"
	"path"
	"path/filepath"

	log "github.com/sirupsen/logrus"

	"github.com/giantswarm/k8s-kvm/pkg/util"
)

const (
	// arch amd-64
	archAMD64 = "amd64-usr"

	// directories
	appDataDirectory = "/var/lib/containervmm"

	// kernel
	vmlinuz          = "flatcar_production_pxe.vmlinuz"
	vmlinuzSignature = vmlinuz + ".sig"

	// initrd
	initrd          = "flatcar_production_pxe_image.cpio.gz"
	initrdSignature = initrd + ".sig"

	// Flatcar image signing key:
	// $ gpg2 --list-keys --list-options show-unusable-subkeys \
	//     --keyid-format SHORT F88CFEDEFF29A5B4D9523864E25D9AED0593B34A
	// pub   rsa4096/0593B34A 2018-02-26 [SC]
	//       F88CFEDEFF29A5B4D9523864E25D9AED0593B34A
	// uid         [ultimate] Flatcar Buildbot (Official Builds) <buildbot@flatcar-linux.org>
	// sub   rsa4096/064D542D 2018-02-26 [S] [revoked: 2018-03-14]
	// sub   rsa4096/D0FC498C 2018-03-14 [S] [revoked: 2018-09-26]
	// sub   rsa4096/896E394F 2018-09-26 [S] [expired: 2019-09-26]
	// sub   rsa4096/AF9CF1AF 2019-09-30 [S] [expires: 2020-09-29]
	// sub   rsa4096/FCBEAB91 2020-08-28 [S] [expires: 2021-08-28]
	buildbotFlatcarPubKey = `
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
ImM5rbOC6ZJdwLUTAg==
=GazO
-----END PGP PUBLIC KEY BLOCK-----
`
)

// Pull Flatcar images from the official Kinvolk repository, optionally verify files and return the image names
func DownloadImages(channel, version string, sanityChecks bool) (string, string, error) {
	vmlinuzPath := filepath.Join(appDataDirectory, "flatcar", channel, version, vmlinuz)
	vmlinuzExistsLocal := util.FileExists(vmlinuzPath)
	if !vmlinuzExistsLocal {
		var vmlinuzURL = assetURL(channel, version, vmlinuz)

		log.Infof("Downloading %s to %s", vmlinuzURL, vmlinuz)

		if err := util.DownloadFile(vmlinuzPath, vmlinuzURL); err != nil {
			return "", "", fmt.Errorf("failed to download file from %s: %w", vmlinuzURL, err)
		}
	} else {
		log.Infof("Image %s found in the local filesystem.", vmlinuz)
	}

	initrdPath := filepath.Join(appDataDirectory, "flatcar", channel, version, initrd)
	initrdExistsLocal := util.FileExists(initrdPath)
	if !initrdExistsLocal {
		var initrdURL = assetURL(channel, version, initrd)

		log.Infof("Downloading %s to %s", initrdURL, initrd)

		if err := util.DownloadFile(initrdPath, initrdURL); err != nil {
			return "", "", fmt.Errorf("failed to download file from %s: %w", initrdURL, err)
		}
	} else {
		log.Infof("Image %s found in the local filesystem", initrd)
	}

	// download images and verify them only when they are downloaded from remote
	// we do trust our filesystem so no need to verify in case are served locally
	if sanityChecks && (!vmlinuzExistsLocal || !initrdExistsLocal) {
		if err := downloadSignatures(channel, version); err != nil {
			return "", "", fmt.Errorf("failed to download signatures: %v", err)
		}

		if err := verifyImages(vmlinuzPath, initrdPath); err != nil {
			return "", "", fmt.Errorf("failed to verify Flatcar images: %w", err)
		}
	} else {
		log.Warningf("Skipping sanity checks.")
	}

	return vmlinuzPath, initrdPath, nil
}

func downloadSignatures(channel, version string) error {
	vmlinuzSignaturePath := filepath.Join(appDataDirectory, "flatcar", channel, version, vmlinuzSignature)
	vmlinuzSignatureURL := assetURL(channel, version, vmlinuzSignature)

	log.Infof("Downloading %s to %s", vmlinuzSignatureURL, vmlinuzSignature)

	if err := util.DownloadFile(vmlinuzSignaturePath, vmlinuzSignatureURL); err != nil {
		return fmt.Errorf("failed to download file from %s: %w", vmlinuzSignatureURL, err)
	}

	initrdSignaturePath := filepath.Join(appDataDirectory, "flatcar", channel, version, initrdSignature)
	var initrdSignatureURL = assetURL(channel, version, initrdSignature)

	log.Infof("Downloading %s to %s", initrdSignatureURL, initrdSignature)

	if err := util.DownloadFile(initrdSignaturePath, initrdSignatureURL); err != nil {
		return fmt.Errorf("failed to download file from %s: %w", initrdSignature, err)
	}

	return nil
}

// Verify Flatcar images with GPG
func verifyImages(vmlinuz, initrd string) error {
	if err := util.VerifyFile(vmlinuz, buildbotFlatcarPubKey); err != nil {
		return fmt.Errorf("failed to verify %s: %v", vmlinuz, err)
	}

	log.Infof("Verified %s", vmlinuz)

	if err := util.VerifyFile(initrd, buildbotFlatcarPubKey); err != nil {
		return fmt.Errorf("failed to verify %s: %v", initrd, err)
	}

	log.Infof("Verified %s", initrd)

	return nil
}

func assetURL(channel, version, image string) string {
	u := url.URL{Scheme: "https"}

	u.Host = fmt.Sprintf("%s.release.flatcar-linux.net", channel)
	u.Path = path.Join(archAMD64, version, image)

	return u.String()
}
