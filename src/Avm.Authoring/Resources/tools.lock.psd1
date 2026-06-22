# Avm.Authoring managed-tool lock file.
#
# Schema (validated by Test-AvmToolsLock):
#
#   @{
#       schemaVersion = 1
#       tools = @(
#           @{
#               name        = '<lowercase-kebab>'    # required
#               version     = '<semver-no-v>'        # required, e.g. '1.9.5'
#               urlTemplate = 'https://...{version}_{os}_{arch}...'
#               archive     = 'zip' | 'tar.gz' | 'raw'
#               entrypoint  = '<binary-basename>'    # lowercase, no .exe
#               sha256      = @{
#                   'windows-amd64' = '<64-hex>'
#                   'windows-arm64' = '<64-hex>'
#                   'linux-amd64'   = '<64-hex>'
#                   'linux-arm64'   = '<64-hex>'
#                   'darwin-amd64'  = '<64-hex>'
#                   'darwin-arm64'  = '<64-hex>'
#               }
#               # OPTIONAL: per-platform asset-name overrides for projects
#               # whose release assets don't follow {os}_{arch} naming
#               # (e.g. bicep). When present, urlTemplate may reference
#               # the {platform} placeholder, which is replaced with the
#               # alias for the resolved platform key.
#               platformAliases = @{
#                   'windows-amd64' = 'win-x64.exe'
#                   'windows-arm64' = 'win-arm64.exe'
#                   'linux-amd64'   = 'linux-x64'
#                   'linux-arm64'   = 'linux-arm64'
#                   'darwin-amd64'  = 'osx-x64'
#                   'darwin-arm64'  = 'osx-arm64'
#               }
#               # OPTIONAL: list of platforms the upstream project does
#               # NOT ship binaries for (e.g. tflint omits windows-arm64).
#               # Those platforms must be ABSENT from sha256; runtime
#               # resolve/install throws AvmToolException AVM1012 if the
#               # current host platform matches.
#               unsupportedPlatforms = @('windows-arm64')
#               # OPTIONAL: per-platform archive override. Use when one
#               # tool ships different archive formats per OS (e.g.
#               # terraform-docs uses .tar.gz on darwin/linux but .zip
#               # on windows). When present, every supported platform
#               # must be listed and 'archive' acts as the documented
#               # default. urlTemplate may reference '{ext}' which
#               # resolves to '.zip' / '.tar.gz' / '' per archive type.
#               archives = @{
#                   'windows-amd64' = 'zip'
#                   'windows-arm64' = 'zip'
#                   'linux-amd64'   = 'tar.gz'
#                   'linux-arm64'   = 'tar.gz'
#                   'darwin-amd64'  = 'tar.gz'
#                   'darwin-arm64'  = 'tar.gz'
#               }
#           }
#       )
#   }
#
# Rules:
#   - All urlTemplate values MUST start with 'https://'. Mirrors are applied at
#     download time via $env:AVM_MIRROR; the lock itself stays canonical.
#     The mirror's scheme, authority, and path prefix are preserved, e.g.
#     AVM_MIRROR='https://m.example.com/proxy' rewrites
#       https://releases.hashicorp.com/terraform/1.9.5/foo.zip
#     to
#       https://m.example.com/proxy/terraform/1.9.5/foo.zip
#     The mirror MUST itself be https://; http:// mirrors are rejected.
#   - {os} resolves to windows|linux|darwin. {arch} resolves to amd64|arm64.
#   - {platform} requires a platformAliases map and resolves per-platform.
#   - {ext} resolves to '.zip' / '.tar.gz' / '' from the per-platform archive
#     (the 'archives' map when present, else the top-level 'archive' field).
#   - sha256 entries are 64-char lowercase hex (SHA256 of the downloaded archive).
#   - sha256 MUST cover every platform except those listed in unsupportedPlatforms.
#   - The 'tools' list MAY be empty (e.g. for fixture / test lockfiles).
#
# Populate canonical entries via:
#   ./scripts/Update-AvmToolsLock.ps1 -Bicep <ver> -Conftest <ver> -Terraform <ver> -TerraformDocs <ver> -Tflint <ver>
@{
    schemaVersion = 1
    tools         = @(
        @{
            name            = 'bicep'
            version         = '0.30.3'
            urlTemplate     = 'https://github.com/Azure/bicep/releases/download/v{version}/bicep-{platform}'
            archive         = 'raw'
            entrypoint      = 'bicep'
            platformAliases = @{
                'windows-amd64' = 'win-x64.exe'
                'windows-arm64' = 'win-arm64.exe'
                'linux-amd64'   = 'linux-x64'
                'linux-arm64'   = 'linux-arm64'
                'darwin-amd64'  = 'osx-x64'
                'darwin-arm64'  = 'osx-arm64'
            }
            sha256          = @{
                'windows-amd64' = '8483fa5dca04fbe435b1e13c6d41faf7f29649d3e6941cde99142823e0eb4105'
                'windows-arm64' = '1ef5ebc66cbe501f817e6abe1bf6d4c4ca29d55d7b199a099c0c622a051633c0'
                'linux-amd64'   = '417b27fcf9dbfc9abc7db3303b3ba56781fee43c2f7ce8f759db9b43d3712d98'
                'linux-arm64'   = '410d6a08a8d82ff43f01879cf93a98e122c3b5b69e733b6921a22f6a80e47f76'
                'darwin-amd64'  = 'ce164b9099a4eee648edf0e9e788dbb2e5e958f2f2f0f76ba8bd655e7fd80735'
                'darwin-arm64'  = 'e299492cf1493f6a3d6dfce2b15801342ba043d62a9383da1bcc6d80263d45b5'
            }
        }
        @{
            name            = 'conftest'
            version         = '0.68.2'
            urlTemplate     = 'https://github.com/open-policy-agent/conftest/releases/download/v{version}/conftest_{version}_{platform}{ext}'
            archive         = 'tar.gz'
            entrypoint      = 'conftest'
            platformAliases = @{
                'windows-amd64' = 'Windows_x86_64'
                'windows-arm64' = 'Windows_arm64'
                'linux-amd64'   = 'Linux_x86_64'
                'linux-arm64'   = 'Linux_arm64'
                'darwin-amd64'  = 'Darwin_x86_64'
                'darwin-arm64'  = 'Darwin_arm64'
            }
            archives        = @{
                'windows-amd64' = 'zip'
                'windows-arm64' = 'zip'
                'linux-amd64'   = 'tar.gz'
                'linux-arm64'   = 'tar.gz'
                'darwin-amd64'  = 'tar.gz'
                'darwin-arm64'  = 'tar.gz'
            }
            sha256          = @{
                'windows-amd64' = '66a88d02e6c03a714e9f0751c3d86ee9c5591739c367ca1b79c4f9f2f90ac4cb'
                'windows-arm64' = 'd727e11a9b6fe05ae87c0261aeee7e59ca8be718d80cb7bf6c57206d1523823d'
                'linux-amd64'   = 'e8144c6d6d2ae0260b869caa60c7c262a1f95ac63ec1e5d2fb19be452d606347'
                'linux-arm64'   = '4005441089655ded475384cb87d57762ae08ebef78305bada49c70530d2f4184'
                'darwin-amd64'  = '7682c54243d2c16579589f55aac47c51389d26f103f828902880288ba7f0605e'
                'darwin-arm64'  = 'cdb5445179e0cc42906e2b0233694900f272a501878d416a9c875b1f7bdfd34c'
            }
        }
        @{
            name        = 'mapotf'
            version     = '0.1.4'
            urlTemplate = 'https://github.com/Azure/mapotf/releases/download/v{version}/mapotf_{version}_{os}_{arch}{ext}'
            archive     = 'tar.gz'
            entrypoint  = 'mapotf'
            archives    = @{
                'windows-amd64' = 'zip'
                'windows-arm64' = 'zip'
                'linux-amd64'   = 'tar.gz'
                'linux-arm64'   = 'tar.gz'
                'darwin-amd64'  = 'tar.gz'
                'darwin-arm64'  = 'tar.gz'
            }
            sha256      = @{
                'windows-amd64' = '9bf52956808a221423384e4a31eb665ddce24e6e6c06ffcf4d5a518f083491e4'
                'windows-arm64' = '40c810461af889ca5919b72d7c7ba5cb77887548cb9b95b7940bf3b24b5c4a79'
                'linux-amd64'   = '3e7bc818c8b08e55f571f5b3561e40fa42807498f4f657fe38a5a4ceeda242cf'
                'linux-arm64'   = 'a87462a7f9261bd9d10906bff543560ad58eff379f392958a0aa931933e4beca'
                'darwin-amd64'  = '43b580b480e6e86e54b0811f08c06a02fbcd0053c522b20548b352f82050df6d'
                'darwin-arm64'  = '4b639d07d5d7cea5934104f2f7c1885d1f32011f5530b2e184b3ac91002e22a5'
            }
        }
        @{
            name        = 'terraform'
            version     = '1.15.3'
            urlTemplate = 'https://releases.hashicorp.com/terraform/{version}/terraform_{version}_{os}_{arch}.zip'
            archive     = 'zip'
            entrypoint  = 'terraform'
            sha256      = @{
                'windows-amd64' = 'b9da8df3d92402551c86b8956be30fb87f600245321d2b31751afcf37218018c'
                'windows-arm64' = 'e4deb6e0aa7739ed8e45032a450731cc4dd7fc09bcdf61f977c881919f7cb3c3'
                'linux-amd64'   = 'c3d4b579064745a5f7e918125db23b12ba52a8a7287adb9f32c49d637e02e3bf'
                'linux-arm64'   = '9824eb010b835b2c872440a337a69acfa1782d36c24d3c09fe5defe75defc511'
                'darwin-amd64'  = '448e89a455e854941bd7e1396ba6ca46e92dd7e0ed1cc11d4da4cab637606d8a'
                'darwin-arm64'  = 'b97101c62c11eebd176e83cd42a313336200d54fdd18ce7770f65a5bfb0ab098'
            }
        }
        @{
            name        = 'terraform-docs'
            version     = '0.20.0'
            urlTemplate = 'https://github.com/terraform-docs/terraform-docs/releases/download/v{version}/terraform-docs-v{version}-{os}-{arch}{ext}'
            archive     = 'tar.gz'
            entrypoint  = 'terraform-docs'
            archives    = @{
                'windows-amd64' = 'zip'
                'windows-arm64' = 'zip'
                'linux-amd64'   = 'tar.gz'
                'linux-arm64'   = 'tar.gz'
                'darwin-amd64'  = 'tar.gz'
                'darwin-arm64'  = 'tar.gz'
            }
            sha256      = @{
                'windows-amd64' = 'fb372a26f934dc0e163ca914a5aa99fe13d094b1f64f937efe9dc79bdddf05a0'
                'windows-arm64' = '1e505ef48aab1ce00f0f13eff247afecaec57f79a0d7353af101de114de2aae3'
                'linux-amd64'   = '34ae01772412bb11474e6718ea62113e38ff5964ee570a98c69fafe3a6dff286'
                'linux-arm64'   = '371b4ed983781d1efdd8f7de06264baac41b1d80927f7fd718c405a303d863a0'
                'darwin-amd64'  = '8c7ea42429d7f5e3dae3de32f3873fde0419332932549147f40916d3f613b8f7'
                'darwin-arm64'  = '8723013cfe0369c389f4e6cb6e3cfca1aebaefd67871e349e7547f2201564dad'
            }
        }
        @{
            name                 = 'tflint'
            version              = '0.55.1'
            urlTemplate          = 'https://github.com/terraform-linters/tflint/releases/download/v{version}/tflint_{os}_{arch}.zip'
            archive              = 'zip'
            entrypoint           = 'tflint'
            unsupportedPlatforms = @(
                'windows-arm64'
            )
            sha256               = @{
                'windows-amd64' = '667e8333eed843298ba1fd1120776784c0dacc17de25e253bc8a67b03adbe87d'
                'linux-amd64'   = '53379f38bc1e86c18885bfc85dc5fe2cd1f59729ae9a2afa16905189c1d67aa9'
                'linux-arm64'   = '3d5d6e1e749ae1d46c153dd6fac358cdfa76df475de8f2660a91ff531021f93b'
                'darwin-amd64'  = '98b1c04030f24b98398413a3a82a9646cd607a958d07576f0151773a6ded30fc'
                'darwin-arm64'  = 'e1f9f843a7bc4cf9631b30e7d65beda6fd5e8013daa91d3a35e23c606a360e50'
            }
        }
    )
}
