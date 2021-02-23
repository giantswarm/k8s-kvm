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

package util

import (
	"compress/gzip"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"strings"

	bar "github.com/schollz/progressbar/v3"
	"golang.org/x/crypto/openpgp"
)

func DownloadFile(file, url string) error {
	dst, err := os.OpenFile(file, os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("failed to open file: %v", err)
	}

	defer dst.Close()

	res, err := http.Get(url)
	if err != nil {
		return fmt.Errorf("failed to get remote resource from %s: %v", url, err)
	}

	defer res.Body.Close()

	switch res.StatusCode {
	case http.StatusOK:
		// create a progress bar
		progress := bar.DefaultBytes(res.ContentLength, "Downloading")

		if _, err = io.Copy(io.MultiWriter(dst, progress), res.Body); err != nil {
			return fmt.Errorf("failed to copy response body into file %s: %v", file, err)
		}
	default:
		return fmt.Errorf("%s: %s", res.Status, res.Request.URL)
	}

	return nil
}

func VerifyFile(file, verifyKey string) error {
	signed, err := os.Open(file)
	if err != nil {
		return err
	}

	defer signed.Close()

	signatureName := file + ".sig"
	signature, err := os.Open(signatureName)

	if err != nil {
		return err
	}

	defer signature.Close()

	return verifyGPG(signed, signature, verifyKey)
}

// verify downloaded file with signature using public signing key
func verifyGPG(signed, signature io.Reader, pubKey string) error {
	keyring, err := openpgp.ReadArmoredKeyRing(strings.NewReader(pubKey))
	if err != nil {
		return fmt.Errorf("failed to read armored public key: %v", err)
	}

	if _, err = openpgp.CheckDetachedSignature(keyring, signed, signature); err != nil {
		return fmt.Errorf("failed to check detached signature: %v", err)
	}

	return nil
}

func DecodeBase64ToFile(encoded, outputPath string) (string, error) {
	base64File, err := os.Open(encoded)
	if err != nil {
		return "", fmt.Errorf("failed to open base64-encoded ignition: %w", err)
	}

	base64Reader := base64.NewDecoder(base64.StdEncoding, base64File)
	gzipReader, err := gzip.NewReader(base64Reader)
	if err != nil {
		return "", fmt.Errorf("failed to unzip ignition: %w", err)
	}

	outputFile := path.Join(outputPath, "ignition.json")
	ignitionWriter, err := os.OpenFile(outputFile, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	if err != nil {
		return "", fmt.Errorf("failed to open ignition output file %s for writing: %w", outputFile, err)
	}

	defer func() {
		localErr := ignitionWriter.Close()
		if localErr != nil {
			_, _ = fmt.Fprintf(os.Stderr, "failed to close ignition output file %s: %s", outputFile, err.Error())
		}
	}()

	_, err = io.Copy(ignitionWriter, gzipReader)
	if err != nil {
		return "", fmt.Errorf("failed to write ignition output file: %w", err)
	}

	return outputFile, nil
}
