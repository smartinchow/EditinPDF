# Third-party notices

EditinPDF is free software. It is built on the work of many other people. This page lists that work and the license each part comes with. It covers everything that is inside the app.

Nothing here limits what the licenses give you. Each license text is shown in full in the section "License texts" at the end.

## EditinPDF

Copyright (c) 2026 EditinPDF contributors

EditinPDF's own code can be used under the MIT License or the Apache License 2.0, as you choose. Both texts are in "License texts" below. The source code is at https://github.com/smartinchow/EditinPDF .

## PdfCraft, the PDF engine

EditinPDF is based on PdfCraft, made by the ArtCraft team and the PdfCraft contributors. PdfCraft reads, draws and edits the PDF files in this app.

Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.

PdfCraft can be used under the MIT License or the Apache License 2.0. Both texts are in "License texts" below. The source code is at https://github.com/storytold/pdfcraft . The ArtCraft name and logos are trademarks of the ArtCraft team. They are not part of this app and are not covered by these licenses.

This is PdfCraft's own NOTICE file, unchanged. Some things it names (for example the program's own window and its icons) are not in this app. The fonts and data that are in this app are listed in the next section.

```
PdfCraft
Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
Licensed under the MIT License or the Apache License, Version 2.0, at your option
(LICENSE-MIT, LICENSE-APACHE).

The ArtCraft name, wordmark and logos in docs/brand/ are trademarks of the ArtCraft Team. They are
not open source and are not covered by the license above; their terms are in
docs/brand/LICENSE-brand.txt.

Third-party material

This product bundles third-party material under its own licenses, listed below. The per-file
list (author, source, license) is in ATTRIBUTION.md.

- Lucide icons (assets/icons/*.svg) — ISC License. See assets/icons/LICENSE-lucide.txt.
  The Windows PDF file icon (assets/app-icon/pdfcraft-document.svg and .ico) adapts Lucide's
  file-text outline and combines it with contributor-original artwork. See
  assets/app-icon/LICENSE-document.txt (ISC AND (MIT OR Apache-2.0)), packaged as
  LICENSE-document.txt beside the Windows executables.
- Inter typeface (assets/fonts/Inter-*.ttf) — SIL Open Font License 1.1. See assets/fonts/OFL-Inter.txt.
- JetBrains Mono typeface (assets/fonts/JetBrainsMono-*.ttf) — SIL Open Font License 1.1. See assets/fonts/OFL-JetBrainsMono.txt.
- Dancing Script typeface (assets/fonts/DancingScript.ttf), Copyright 2016 The Dancing Script Project Authors — SIL Open Font License 1.1 (Reserved Font Name "Dancing Script"). See assets/fonts/OFL-DancingScript.txt.
- Fonts from craft-fonts (https://github.com/storytold/craft-fonts), an optional build input
  (CRAFT_FONTS_DIR) that is not part of this repository. Builds made with it, which includes every
  official release, embed the fonts listed in
  https://github.com/storytold/craft-fonts/blob/main/ATTRIBUTION.md (BIZ UDPGothic, Shippori Mincho,
  BIZ UDMincho; the web build only BIZ UDPGothic Regular) under the SIL Open Font License 1.1. Those
  packages carry each font's licence as OFL-<family>.txt. Builds made with the craft-fonts revision
  pinned in .github/workflows/ also include Noto Sans Thai (in the web build too), Copyright 2022
  The Noto Project Authors (https://github.com/notofonts/thai), under SIL OFL 1.1; its licence is
  fonts/noto-sans-thai/OFL.txt in the craft-fonts build input.
- hayro (rendering, via crates.io) — Apache-2.0 OR MIT. Its `embed-fonts` feature bundles the Foxit
  standard-14 Type 1 fonts under BSD-3-Clause ("Copyright 2014 PDFium Authors"), and hayro-cmap bundles
  Adobe CMap resources under BSD-3-Clause.
- lopdf (bootstrap document inspection, via crates.io) — MIT.
- egui default fonts (epaint_default_fonts, via eframe) — Ubuntu Light (Ubuntu Font Licence 1.0),
  Hack (MIT / Bitstream Vera licence), Noto Emoji (SIL OFL 1.1), emoji-icon-font (MIT).
- Colour profile in hayro-interpret — CGATS001Compat-v2-micro.icc (CC0-1.0, Clinton Ingram).

Required notices:

  Foxit standard-14 substitute fonts (vendor/hayro-interpret/assets/*.pfb):
    Copyright 2014 PDFium Authors. All rights reserved. Original code copyright 2014 Foxit Software Inc.
    Redistributed under the BSD-3-Clause licence in vendor/hayro-interpret/assets/LICENSE_FOXIT.

  CMap resources (bundled by hayro-cmap; character-mapping data, not visual assets):
    Copyright 1990-2023 Adobe. All rights reserved. Redistributed under the BSD-3-Clause licence
    (https://github.com/adobe-type-tools/cmap-resources/blob/master/LICENSE.txt). Neither the name of
    Adobe nor the names of its contributors are used to endorse or promote this product.

Showcase PDF (built by `cargo xtask demo-pdf`, not committed): fonts are downloaded at build time from
google/fonts at a pinned commit, verified by SHA-256, all under the SIL Open Font License 1.1 — see the
"Downloaded at build time" table in ATTRIBUTION.md.

Asset licences are not visible to cargo-deny; keep this file current whenever assets or asset-bundling
dependencies change (plan/adr/0002, 0006).

Vendored (vendor/, patched; see vendor/README.md):
- hayro 0.7.1 — Apache-2.0 OR MIT, Copyright the hayro authors (licence files kept in vendor/hayro).
- hayro-interpret 0.7.0 — Apache-2.0 OR MIT, Copyright the hayro authors (LICENSE-APACHE, LICENSE-MIT kept in vendor/hayro-interpret).
```

## Fonts and data inside the engine

The engine has these fonts and data files built into it. This list was made by reading what the engine's source code puts into the program (`include_bytes!`) and which features of its libraries are switched on in this build. Not in this app: the optional craft-fonts collection (Japanese and other fonts), the text-recognition models, the icon set and fonts of PdfCraft's desktop window, and the egui libraries.

- **Adobe CMap resources (data, in hayro-cmap)**. License: BSD-3-Clause. Character tables for reading Chinese, Japanese and Korean PDFs.
  - Copyright 1990-2023 Adobe. All rights reserved.
- **CGATS001Compat v2 micro color profile (in hayro-interpret)**. License: CC0-1.0. Turns CMYK colors into screen colors.
  - Clinton Ingram (saucecontrol/Compact-ICC-Profiles), dedicated to the public domain
- **Dancing Script (font)**. License: OFL-1.1. Used to draw typed signatures.
  - Copyright 2016 The Dancing Script Project Authors (https://github.com/googlefonts/DancingScript), with Reserved Font Name 'Dancing Script'.
- **Foxit standard-14 substitute fonts (from PDFium, in hayro-interpret)**. License: BSD-3-Clause. Show the 14 standard PDF fonts when a document does not carry them.
  - Copyright 2014 PDFium Authors. All rights reserved.
  - Original code copyright 2014 Foxit Software Inc.
- **Inter Regular (font)**. License: OFL-1.1. Used to draw typed signatures for letters Dancing Script does not have.
  - Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter)

## Code libraries

The app contains 330 Rust libraries (crates), found with `cargo about` from `core/Cargo.lock`, for the iPhone and iPad targets, without tools used only to build or test. This includes PdfCraft's own crates and two patched copies kept in this repository: `num_threads` (core/vendor/num_threads, changed so it builds for iOS; the changes are described in PATCH.md there) and the PdfCraft copies of `hayro` and `lopdf`.

Many libraries offer a choice of licenses. The list below shows the license we accept for each. You can find the source code of each library at https://crates.io/crates/NAME , with NAME replaced by its name. The libraries are used as published; the source of the uniffi libraries (MPL-2.0) is also at https://github.com/mozilla/uniffi-rs .

The app uses no Swift packages from other people. Apple's own system frameworks are not listed.

## Licenses in this app

- Apache-2.0: Apache License 2.0 (7)
- BSD-3-Clause: BSD 3-Clause "New" or "Revised" License (11)
- CC0-1.0: Creative Commons CC0 1.0 Universal (1)
- ISC: ISC License (2)
- MIT: MIT License (298)
- MPL-2.0: Mozilla Public License 2.0 (6)
- OFL-1.1: SIL Open Font License 1.1 (2)
- Unicode-3.0: Unicode License v3 (19)
- Zlib: zlib License (1)

## License texts

For each license: the text, then the components that use it with the copyright lines they carry.

### Apache-2.0: Apache License 2.0

#### Apache-2.0, form 1 of 3

```
Apache License
Version 2.0, January 2004
http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

"License" shall mean the terms and conditions for use, reproduction, and distribution as defined by Sections 1 through 9 of this document.

"Licensor" shall mean the copyright owner or entity authorized by the copyright owner that is granting the License.

"Legal Entity" shall mean the union of the acting entity and all other entities that control, are controlled by, or are under common control with that entity. For the purposes of this definition, "control" means (i) the power, direct or indirect, to cause the direction or management of such entity, whether by contract or otherwise, or (ii) ownership of fifty percent (50%) or more of the outstanding shares, or (iii) beneficial ownership of such entity.

"You" (or "Your") shall mean an individual or Legal Entity exercising permissions granted by this License.

"Source" form shall mean the preferred form for making modifications, including but not limited to software source code, documentation source, and configuration files.

"Object" form shall mean any form resulting from mechanical transformation or translation of a Source form, including but not limited to compiled object code, generated documentation, and conversions to other media types.

"Work" shall mean the work of authorship, whether in Source or Object form, made available under the License, as indicated by a copyright notice that is included in or attached to the work (an example is provided in the Appendix below).

"Derivative Works" shall mean any work, whether in Source or Object form, that is based on (or derived from) the Work and for which the editorial revisions, annotations, elaborations, or other modifications represent, as a whole, an original work of authorship. For the purposes of this License, Derivative Works shall not include works that remain separable from, or merely link (or bind by name) to the interfaces of, the Work and Derivative Works thereof.

"Contribution" shall mean any work of authorship, including the original version of the Work and any modifications or additions to that Work or Derivative Works thereof, that is intentionally submitted to Licensor for inclusion in the Work by the copyright owner or by an individual or Legal Entity authorized to submit on behalf of the copyright owner. For the purposes of this definition, "submitted" means any form of electronic, verbal, or written communication sent to the Licensor or its representatives, including but not limited to communication on electronic mailing lists, source code control systems, and issue tracking systems that are managed by, or on behalf of, the Licensor for the purpose of discussing and improving the Work, but excluding communication that is conspicuously marked or otherwise designated in writing by the copyright owner as "Not a Contribution."

"Contributor" shall mean Licensor and any individual or Legal Entity on behalf of whom a Contribution has been received by Licensor and subsequently incorporated within the Work.

2. Grant of Copyright License. Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable copyright license to reproduce, prepare Derivative Works of, publicly display, publicly perform, sublicense, and distribute the Work and such Derivative Works in Source or Object form.

3. Grant of Patent License. Subject to the terms and conditions of this License, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable (except as stated in this section) patent license to make, have made, use, offer to sell, sell, import, and otherwise transfer the Work, where such license applies only to those patent claims licensable by such Contributor that are necessarily infringed by their Contribution(s) alone or by combination of their Contribution(s) with the Work to which such Contribution(s) was submitted. If You institute patent litigation against any entity (including a cross-claim or counterclaim in a lawsuit) alleging that the Work or a Contribution incorporated within the Work constitutes direct or contributory patent infringement, then any patent licenses granted to You under this License for that Work shall terminate as of the date such litigation is filed.

4. Redistribution. You may reproduce and distribute copies of the Work or Derivative Works thereof in any medium, with or without modifications, and in Source or Object form, provided that You meet the following conditions:

     (a) You must give any other recipients of the Work or Derivative Works a copy of this License; and

     (b) You must cause any modified files to carry prominent notices stating that You changed the files; and

     (c) You must retain, in the Source form of any Derivative Works that You distribute, all copyright, patent, trademark, and attribution notices from the Source form of the Work, excluding those notices that do not pertain to any part of the Derivative Works; and

     (d) If the Work includes a "NOTICE" text file as part of its distribution, then any Derivative Works that You distribute must include a readable copy of the attribution notices contained within such NOTICE file, excluding those notices that do not pertain to any part of the Derivative Works, in at least one of the following places: within a NOTICE text file distributed as part of the Derivative Works; within the Source form or documentation, if provided along with the Derivative Works; or, within a display generated by the Derivative Works, if and wherever such third-party notices normally appear. The contents of the NOTICE file are for informational purposes only and do not modify the License. You may add Your own attribution notices within Derivative Works that You distribute, alongside or as an addendum to the NOTICE text from the Work, provided that such additional attribution notices cannot be construed as modifying the License.

     You may add Your own copyright statement to Your modifications and may provide additional or different license terms and conditions for use, reproduction, or distribution of Your modifications, or for any such Derivative Works as a whole, provided Your use, reproduction, and distribution of the Work otherwise complies with the conditions stated in this License.

5. Submission of Contributions. Unless You explicitly state otherwise, any Contribution intentionally submitted for inclusion in the Work by You to the Licensor shall be under the terms and conditions of this License, without any additional terms or conditions. Notwithstanding the above, nothing herein shall supersede or modify the terms of any separate license agreement you may have executed with Licensor regarding such Contributions.

6. Trademarks. This License does not grant permission to use the trade names, trademarks, service marks, or product names of the Licensor, except as required for reasonable and customary use in describing the origin of the Work and reproducing the content of the NOTICE file.

7. Disclaimer of Warranty. Unless required by applicable law or agreed to in writing, Licensor provides the Work (and each Contributor provides its Contributions) on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied, including, without limitation, any warranties or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A PARTICULAR PURPOSE. You are solely responsible for determining the appropriateness of using or redistributing the Work and assume any risks associated with Your exercise of permissions under this License.

8. Limitation of Liability. In no event and under no legal theory, whether in tort (including negligence), contract, or otherwise, unless required by applicable law (such as deliberate and grossly negligent acts) or agreed to in writing, shall any Contributor be liable to You for damages, including any direct, indirect, special, incidental, or consequential damages of any character arising as a result of this License or out of the use or inability to use the Work (including but not limited to damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses), even if such Contributor has been advised of the possibility of such damages.

9. Accepting Warranty or Additional Liability. While redistributing the Work or Derivative Works thereof, You may choose to offer, and charge a fee for, acceptance of support, warranty, indemnity, or other liability obligations and/or rights consistent with this License. However, in accepting such obligations, You may act only on Your own behalf and on Your sole responsibility, not on behalf of any other Contributor, and only if You agree to indemnify, defend, and hold each Contributor harmless for any liability incurred by, or claims asserted against, such Contributor by reason of your accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS

APPENDIX: How to apply the Apache License to your work.

To apply the Apache License to your work, attach the following boilerplate notice, with the fields enclosed by brackets "[]" replaced with your own identifying information. (Don't include the brackets!)  The text should be enclosed in the appropriate comment syntax for the file format. We also recommend that a file or class name and description of purpose be included on the same "printed page" as the copyright notice for easier identification within third-party archives.

Copyright [yyyy] [name of copyright owner]

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

Used by (3):

- aws-lc-sys 0.46.0: by AWS-LC
- flatbuffers 24.12.23: by FlatBuffers Maintainers, Robert Winslow
- ryu-js 1.0.3: by David Tolnay, boa-dev

#### Apache-2.0, form 2 of 3

```
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

Used by (3):

- moxcms 0.8.1: Copyright 2024 Radzivon Bartoshyk
- pic-scale 0.7.12: Copyright 2024 Radzivon Bartoshyk
- pxfm 0.1.30: Copyright 2024 Radzivon Bartoshyk

#### Apache-2.0, form 3 of 3

```
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS
```

Used by (1):

- EditinPDF

### BSD-3-Clause: BSD 3-Clause "New" or "Revised" License

#### BSD-3-Clause, form 1 of 5

```
Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

Used by (6):

- alloc-stdlib 0.2.4: by Daniel Reiter Horn
- aws-lc-sys 0.46.0: by AWS-LC
- curve25519-dalek 5.0.0: Copyright (c) 2016-2021 Henry de Valence. All rights reserved.; Copyright (c) 2016-2021 isis agora lovecruft. All rights reserved.
- ed25519-dalek 3.0.0: Copyright (c) 2017-2019 isis agora lovecruft. All rights reserved.
- encoding_rs 0.8.42: Copyright © WHATWG (Apple, Google, Mozilla, Microsoft).
- subtle 2.6.1: Copyright (c) 2016-2017 Isis Agora Lovecruft, Henry de Valence. All rights reserved.; Copyright (c) 2016-2024 Isis Agora Lovecruft. All rights reserved.

#### BSD-3-Clause, form 2 of 5

```
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

Used by (2):

- alloc-no-stdlib 2.0.4: Copyright (c) 2016 Dropbox, Inc.
- brotli 8.0.4: Copyright (c) 2016 Dropbox, Inc.

#### BSD-3-Clause, form 3 of 5

```
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

Neither the name of Adobe nor the names of its contributors may be
used to endorse or promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

Used by (1):

- Adobe CMap resources (data, in hayro-cmap): Copyright 1990-2023 Adobe. All rights reserved.

#### BSD-3-Clause, form 4 of 5

```
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

Used by (1):

- Foxit standard-14 substitute fonts (from PDFium, in hayro-interpret): Copyright 2014 PDFium Authors. All rights reserved.; Original code copyright 2014 Foxit Software Inc.

#### BSD-3-Clause, form 5 of 5

```
// Copyright © WHATWG (Apple, Google, Mozilla, Microsoft).
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

/// The PUA code points special-cased in the GB18030 encoder.
pub(crate) static GB18030_2022_OVERRIDE_PUA: [u16; 18] = [
    0xE78D, 0xE78E, 0xE78F, 0xE790, 0xE791, 0xE792, 0xE793, 0xE794, 0xE795, 0xE796, 0xE81E, 0xE826,
    0xE82B, 0xE82C, 0xE832, 0xE843, 0xE854, 0xE864,
];

/// The bytes corresponding to the PUA code points special-cased in the GB18030 encoder.
pub(crate) static GB18030_2022_OVERRIDE_BYTES: [[u8; 2]; 18] = [
    [0xA6, 0xD9],
    [0xA6, 0xDA],
    [0xA6, 0xDB],
    [0xA6, 0xDC],
    [0xA6, 0xDD],
    [0xA6, 0xDE],
    [0xA6, 0xDF],
    [0xA6, 0xEC],
    [0xA6, 0xED],
    [0xA6, 0xF3],
    [0xFE, 0x59],
    [0xFE, 0x61],
    [0xFE, 0x66],
    [0xFE, 0x67],
    [0xFE, 0x6D],
    [0xFE, 0x7E],
    [0xFE, 0x90],
    [0xFE, 0xA0],
];
```

Used by (1):

- encoding_rs 0.8.42: by Henri Sivonen

### CC0-1.0: Creative Commons CC0 1.0 Universal

```
CC0 1.0 Universal

Statement of Purpose

The laws of most jurisdictions throughout the world automatically confer
exclusive Copyright and Related Rights (defined below) upon the creator and
subsequent owner(s) (each and all, an "owner") of an original work of
authorship and/or a database (each, a "Work").

Certain owners wish to permanently relinquish those rights to a Work for the
purpose of contributing to a commons of creative, cultural and scientific
works ("Commons") that the public can reliably and without fear of later
claims of infringement build upon, modify, incorporate in other works, reuse
and redistribute as freely as possible in any form whatsoever and for any
purposes, including without limitation commercial purposes. These owners may
contribute to the Commons to promote the ideal of a free culture and the
further production of creative, cultural and scientific works, or to gain
reputation or greater distribution for their Work in part through the use and
efforts of others.

For these and/or other purposes and motivations, and without any expectation
of additional consideration or compensation, the person associating CC0 with a
Work (the "Affirmer"), to the extent that he or she is an owner of Copyright
and Related Rights in the Work, voluntarily elects to apply CC0 to the Work
and publicly distribute the Work under its terms, with knowledge of his or her
Copyright and Related Rights in the Work and the meaning and intended legal
effect of CC0 on those rights.

1. Copyright and Related Rights. A Work made available under CC0 may be
protected by copyright and related or neighboring rights ("Copyright and
Related Rights"). Copyright and Related Rights include, but are not limited
to, the following:

  i. the right to reproduce, adapt, distribute, perform, display, communicate,
  and translate a Work;

  ii. moral rights retained by the original author(s) and/or performer(s);

  iii. publicity and privacy rights pertaining to a person's image or likeness
  depicted in a Work;

  iv. rights protecting against unfair competition in regards to a Work,
  subject to the limitations in paragraph 4(a), below;

  v. rights protecting the extraction, dissemination, use and reuse of data in
  a Work;

  vi. database rights (such as those arising under Directive 96/9/EC of the
  European Parliament and of the Council of 11 March 1996 on the legal
  protection of databases, and under any national implementation thereof,
  including any amended or successor version of such directive); and

  vii. other similar, equivalent or corresponding rights throughout the world
  based on applicable law or treaty, and any national implementations thereof.

2. Waiver. To the greatest extent permitted by, but not in contravention of,
applicable law, Affirmer hereby overtly, fully, permanently, irrevocably and
unconditionally waives, abandons, and surrenders all of Affirmer's Copyright
and Related Rights and associated claims and causes of action, whether now
known or unknown (including existing as well as future claims and causes of
action), in the Work (i) in all territories worldwide, (ii) for the maximum
duration provided by applicable law or treaty (including future time
extensions), (iii) in any current or future medium and for any number of
copies, and (iv) for any purpose whatsoever, including without limitation
commercial, advertising or promotional purposes (the "Waiver"). Affirmer makes
the Waiver for the benefit of each member of the public at large and to the
detriment of Affirmer's heirs and successors, fully intending that such Waiver
shall not be subject to revocation, rescission, cancellation, termination, or
any other legal or equitable action to disrupt the quiet enjoyment of the Work
by the public as contemplated by Affirmer's express Statement of Purpose.

3. Public License Fallback. Should any part of the Waiver for any reason be
judged legally invalid or ineffective under applicable law, then the Waiver
shall be preserved to the maximum extent permitted taking into account
Affirmer's express Statement of Purpose. In addition, to the extent the Waiver
is so judged Affirmer hereby grants to each affected person a royalty-free,
non transferable, non sublicensable, non exclusive, irrevocable and
unconditional license to exercise Affirmer's Copyright and Related Rights in
the Work (i) in all territories worldwide, (ii) for the maximum duration
provided by applicable law or treaty (including future time extensions), (iii)
in any current or future medium and for any number of copies, and (iv) for any
purpose whatsoever, including without limitation commercial, advertising or
promotional purposes (the "License"). The License shall be deemed effective as
of the date CC0 was applied by Affirmer to the Work. Should any part of the
License for any reason be judged legally invalid or ineffective under
applicable law, such partial invalidity or ineffectiveness shall not
invalidate the remainder of the License, and in such case Affirmer hereby
affirms that he or she will not (i) exercise any of his or her remaining
Copyright and Related Rights in the Work or (ii) assert any associated claims
and causes of action with respect to the Work, in either case contrary to
Affirmer's express Statement of Purpose.

4. Limitations and Disclaimers.

  a. No trademark or patent rights held by Affirmer are waived, abandoned,
  surrendered, licensed or otherwise affected by this document.

  b. Affirmer offers the Work as-is and makes no representations or warranties
  of any kind concerning the Work, express, implied, statutory or otherwise,
  including without limitation warranties of title, merchantability, fitness
  for a particular purpose, non infringement, or the absence of latent or
  other defects, accuracy, or the present or absence of errors, whether or not
  discoverable, all to the greatest extent permissible under applicable law.

  c. Affirmer disclaims responsibility for clearing rights of other persons
  that may apply to the Work or any use thereof, including without limitation
  any person's Copyright and Related Rights in the Work. Further, Affirmer
  disclaims responsibility for obtaining any necessary consents, permissions
  or other rights required for any use of the Work.

  d. Affirmer understands and acknowledges that Creative Commons is not a
  party to this document and has no duty or obligation with respect to this
  CC0 or use of the Work.

For more information, please see
http://creativecommons.org/publicdomain/zero/1.0/
```

Used by (1):

- CGATS001Compat v2 micro color profile (in hayro-interpret): Clinton Ingram (saucecontrol/Compact-ICC-Profiles), dedicated to the public domain

### ISC: ISC License

```
ISC License

Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

Used by (2):

- aws-lc-rs 1.18.2: by AWS-LibCrypto
- aws-lc-sys 0.46.0: by AWS-LC

### MIT: MIT License

#### MIT, form 1 of 8

```
Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

Used by (182):

- adler2 2.0.1: by Jonas Schievink, oyvindln
- aes 0.9.3: Copyright (c) 2018 Artyom Pavlov; Copyright (c) 2018-2024 The RustCrypto Project Developers
- allocator-api2 0.2.21: by Zakarum
- anyhow 1.0.104: by David Tolnay
- arrayvec 0.7.8: Copyright (c) Ulrik Sverdrup "bluss" 2015-2023
- async-channel 2.5.0: by Stjepan Glavina
- base16ct 1.0.0: Copyright (c) 2014 Steve "Sc00bz" Thomas (steve at tobtu dot com); Copyright (c) 2022-2025 The RustCrypto Project Developers
- bitflags 1.3.2: Copyright (c) 2014 The Rust Project Developers
- bitflags 2.13.2: Copyright (c) 2014 The Rust Project Developers
- block-buffer 0.12.1: Copyright (c) 2018-2025 The RustCrypto Project Developers
- block-padding 0.4.2: Copyright (c) 2018-2025 The RustCrypto Project Developers
- bp256 0.14.0: Copyright (c) 2021-2023 RustCrypto Developers
- bp384 0.14.0: Copyright (c) 2021-2023 RustCrypto Developers
- brotli 8.0.4: Copyright (c) 2009, 2010, 2013-2016 by the Brotli Authors.
- bytes 1.12.1: Copyright (c) 2018 Carl Lerche
- camino 1.2.6: by Ashley Williams, Rain, Steve Klabnik, Without Boats
- cargo-platform 0.3.3
- cargo_metadata 0.23.1: by Oliver Schneider
- cbc 0.2.1: Copyright (c) 2018 Artyom Pavlov; Copyright (c) 2018-2022 RustCrypto Developers
- cfg-if 1.0.5: Copyright (c) 2014 Alex Crichton
- chacha20 0.10.2: Copyright (c) 2019-2026 The RustCrypto Project Developers
- cipher 0.5.2: Copyright (c) 2016-2025 RustCrypto Developers
- cmov 0.5.4: Copyright (c) 2022-2026 The RustCrypto Project Developers
- concurrent-queue 2.5.0: by John Nunley, Stjepan Glavina, Taiki Endo
- const-oid 0.10.2: Copyright (c) 2020-2026 The RustCrypto Project Developers
- core-foundation-sys 0.8.7: Copyright (c) 2012-2013 Mozilla Foundation
- cpubits 0.1.1: Copyright (c) 2023-2026 The RustCrypto Project Developers
- cpufeatures 0.3.1: Copyright (c) 2020-2026 The RustCrypto Project Developers
- crypto-bigint 0.7.5: Copyright (c) 2021-2026 The RustCrypto Project Developers
- crypto-common 0.2.2: Copyright (c) 2021-2026 RustCrypto Developers
- ctutils 0.4.3: Copyright (c) 2025-2026 The RustCrypto Project Developers
- der 0.8.2: Copyright (c) 2020-2026 The RustCrypto Project Developers
- deranged 0.5.9: Copyright (c) 2024 Jacob Pratt et al.
- des 0.9.0: Copyright (c) 2017 Gulshan Singh, Antoni Boucher, Artyom Pavlov; Copyright (c) 2017-2024 The RustCrypto Project Developers
- digest 0.11.3: Copyright (c) 2017 Artyom Pavlov; Copyright (c) 2017-2025 RustCrypto Developers
- displaydoc 0.2.7: by Jane Lusby
- dynify 0.1.2: by Loi Chyan
- dynify-macros 0.1.2: by Loi Chyan
- ecb 0.2.1: Copyright (c) 2026 RustCrypto Developers
- ecdsa 0.17.0: Copyright (c) 2018-2026 RustCrypto Developers
- ed25519 3.0.0: Copyright (c) 2018-2026 RustCrypto Developers
- either 1.19.0: Copyright (c) 2015
- elliptic-curve 0.14.1: Copyright (c) 2020-2026 RustCrypto Developers
- encoding_rs 0.8.42: Copyright Mozilla Foundation
- equivalent 1.0.3: Copyright (c) 2016--2023
- errno 0.3.14: Copyright (c) 2014 Chris Wong
- euclid 0.22.14: Copyright (c) 2012-2013 Mozilla Foundation
- event-listener 5.4.2: by John Nunley, Stjepan Glavina
- event-listener-strategy 0.5.4: by John Nunley
- fast-float2 0.2.4: by Alex Huszagh, Ivan Smirnov
- fastrand 2.5.0: by Stjepan Glavina
- fearless_simd 0.4.1: Copyright (c) 2018 Raph Levien
- fixedbitset 0.5.7: Copyright (c) 2015-2017
- flate2 1.1.10: Copyright (c) 2014-2026 Alex Crichton
- font-types 0.12.6: Copyright (c) 2019 Fontations Developers
- form_urlencoded 1.2.2: Copyright (c) 2013-2016 The rust-url developers
- fs-err 3.3.2: by Andrew Hickman
- futures-core 0.3.34: Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors
- futures-io 0.3.34: Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors
- futures-lite 2.6.1: by Contributors to futures-rs, Stjepan Glavina
- getrandom 0.4.3: Copyright (c) 2014 The Rust Project Developers; Copyright (c) 2018-2026 The rust-random Project Developers
- group 0.14.0: by Jack Grigg, Sean Bowe
- hashbrown 0.14.5: Copyright (c) 2016 Amanieu d'Antras
- hashbrown 0.17.1: Copyright (c) 2016 Amanieu d'Antras
- heck 0.5.0: Copyright (c) 2015 The Rust Project Developers
- hmac 0.13.0: Copyright (c) 2017 Artyom Pavlov
- hybrid-array 0.4.15: Copyright (c) 2022-2026 The RustCrypto Project Developers
- iana-time-zone 0.1.65: Copyright (c) 2020 Andrew D. Straw
- idna 1.1.0: Copyright (c) 2013-2025 The rust-url developers
- idna_adapter 1.2.2: Copyright (c) The rust-url developers
- indexmap 2.14.2: Copyright (c) 2016--2017
- inout 0.2.3: Copyright (c) 2022 Artyom Pavlov; Copyright (c) 2022-2025 The RustCrypto Project Developers
- intrusive-collections 0.10.3: Copyright (c) 2016 Amanieu d'Antras
- itertools 0.15.0: Copyright (c) 2015
- itoa 1.0.18: by David Tolnay
- keccak 0.2.2: Copyright (c) 2018-2026 The RustCrypto Project Developers
- kurbo 0.13.1: Copyright (c) 2018 Raph Levien
- libc 0.2.190: Copyright (c) The Rust Project Developers
- lock_api 0.4.14: Copyright (c) 2016 The Rust Project Developers
- log 0.4.34: Copyright (c) 2014 The Rust Project Developers
- md-5 0.11.0: Copyright (c) 2006-2009 Graydon Hoare; Copyright (c) 2009-2013 Mozilla Foundation; Copyright (c) 2016 Artyom Pavlov; Copyright (c) 2016-2026 The RustCrypto Project Developers
- multiversion_no_op 1.0.0: Copyright Mozilla Foundation
- nom 8.0.0: Copyright (c) 2014-2019 Geoffroy Couprie
- num-bigint 0.5.1: Copyright (c) 2014 The Rust Project Developers
- num-conv 0.2.2: Copyright (c) Jacob Pratt
- num-integer 0.1.47: Copyright (c) 2014 The Rust Project Developers
- num-traits 0.2.19: Copyright (c) 2014 The Rust Project Developers
- num_cpus 1.17.0: Copyright (c) 2015-2025 Sean McArthur
- num_enum 0.7.6: by Daniel Henry-Mantilla, Daniel Wagner-Hall, Vincent Esche
- num_enum_derive 0.7.6: by Daniel Henry-Mantilla, Daniel Wagner-Hall, Vincent Esche
- num_threads 0.1.7: Copyright (c) 2021 Jacob Pratt
- once_cell 1.21.4: by Aleksey Kladov
- oneshot 0.2.1: by Linus Färnstrand
- p256 0.14.0: Copyright (c) 2020-2026 RustCrypto Developers
- p384 0.14.0: Copyright (c) 2020-2021 RustCrypto Developers
- p521 0.14.0: Copyright (c) 2020-2026 RustCrypto Developers
- parking 2.2.1: by Stjepan Glavina, The Rust Project Developers
- parking_lot_core 0.9.12: Copyright (c) 2016 The Rust Project Developers
- pastey 0.2.3: by Aditya Kumar, David Tolnay
- pbkdf2 0.13.0: Copyright (c) 2017 Artyom Pavlov; Copyright (c) 2018-2023 The RustCrypto Project Developers
- peniko 0.6.1: Copyright (c) 2018 Raph Levien
- percent-encoding 2.3.2: Copyright (c) 2013-2025 The rust-url developers
- pin-project 1.1.13
- pin-project-internal 1.1.13
- pin-project-lite 0.2.17
- png 0.18.1: Copyright (c) 2015 nwin
- polycool 0.4.0: Copyright (c) 2018 Raph Levien
- portable-atomic 1.15.0
- powerfmt 0.2.1: Copyright (c) 2023 Jacob Pratt et al.
- primefield 0.14.0: Copyright (c) 2024-2026 RustCrypto Developers
- primeorder 0.14.0: Copyright (c) 2020-2023 RustCrypto Developers
- proc-macro-crate 3.5.0: by Bastian Köcher
- proc-macro2 1.0.107: by Alex Crichton, David Tolnay
- quick-error 2.0.1: Copyright (c) 2015 The quick-error Developers
- quote 1.0.47: by David Tolnay
- rand 0.10.3: Copyright (c) 2014 The Rust Project Developers; Copyright 2018 Developers of the Rand project
- rand_core 0.10.1: Copyright (c) 2018-2026 The Rand Project Developers
- rangemap 1.8.0: Copyright 2019 Jeffrey Parsons
- rayon 1.12.0: Copyright (c) 2010 The Rust Project Developers
- rayon-core 1.13.0: Copyright (c) 2010 The Rust Project Developers
- rc2 0.9.0: Copyright (c) 2017 Damian Czaja; Copyright (c) 2017-2024 The RustCrypto Project Developers
- read-fonts 0.41.0: Copyright (c) 2019 Fontations Developers
- read-fonts 0.44.0: Copyright (c) 2019 Fontations Developers
- rfc6979 0.6.0: Copyright (c) 2018-2026 RustCrypto Developers
- ripemd 0.2.0: Copyright (c) 2021-2026 The RustCrypto Project Developers
- rsa 0.10.0-rc.18: by RustCrypto Developers, dignifiedquire
- rustc-hash 2.1.3: by The Rust Project Developers
- rustix 1.1.5: by Dan Gohman, Jakub Konka
- rustversion 1.0.23: by David Tolnay
- scopeguard 1.2.0: Copyright (c) 2016-2019 Ulrik Sverdrup "bluss" and scopeguard developers
- sec1 0.8.1: Copyright (c) 2021-2026 The RustCrypto Project Developers
- semver 1.0.28: by David Tolnay
- serde 1.0.229: by David Tolnay, Erick Tryzelaar
- serde_core 1.0.229: by David Tolnay, Erick Tryzelaar
- serde_derive 1.0.229: by David Tolnay, Erick Tryzelaar
- serde_json 1.0.154
- serde_spanned 1.1.2: Copyright (c) Individual contributors
- sha1 0.11.0: Copyright (c) 2006-2009 Graydon Hoare; Copyright (c) 2009-2013 Mozilla Foundation; Copyright (c) 2016 Artyom Pavlov; Copyright (c) 2016-2026 The RustCrypto Project Developers
- sha2 0.11.1: Copyright (c) 2006-2009 Graydon Hoare; Copyright (c) 2009-2013 Mozilla Foundation; Copyright (c) 2016 Artyom Pavlov; Copyright (c) 2016-2026 The RustCrypto Project Developers
- sha3 0.12.0: Copyright (c) 2006-2009 Graydon Hoare; Copyright (c) 2009-2013 Mozilla Foundation; Copyright (c) 2014 Sébastien Martini; Copyright (c) 2016-2023 Artyom Pavlov, Marek Kotewicz; Copyright (c) 2020-2026 The RustCrypto Project Developers
- signature 3.0.0: Copyright (c) 2018-2026 RustCrypto Developers
- siphasher 1.0.4: by Frank Denis
- skrifa 0.44.0: Copyright (c) 2019 Fontations Developers
- skrifa 0.47.0: Copyright (c) 2019 Fontations Developers
- smallvec 1.16.3: Copyright (c) 2018 The Servo Project Developers
- spki 0.8.1: Copyright (c) 2021-2026 The RustCrypto Project Developers
- sponge-cursor 0.1.0: Copyright (c) 2026 The RustCrypto Project Developers
- stable_deref_trait 1.2.1: Copyright (c) 2017 Robert Grosse
- stringprep 0.1.5: Copyright (c) 2017 The rust-stringprep Developers
- syn 2.0.119: by David Tolnay
- syn 3.0.9: by David Tolnay
- synstructure 0.14.0: Copyright 2016 Nika Layzell
- tempfile 3.27.0: Copyright (c) 2015 Steven Allen
- thin-vec 0.2.21: by Aria Beingessner
- thiserror 2.0.21: by David Tolnay
- thiserror-impl 2.0.21: by David Tolnay
- time 0.3.55: Copyright (c) Jacob Pratt et al.
- time-core 0.1.9: Copyright (c) Jacob Pratt et al.
- time-macros 0.2.32: Copyright (c) Jacob Pratt et al.
- tinyvec 1.13.3: by Lokathor
- toml 1.1.8+spec-1.1.0: Copyright (c) Individual contributors
- toml_datetime 1.1.2+spec-1.1.0: Copyright (c) Individual contributors
- toml_edit 0.25.17+spec-1.1.0: Copyright (c) Individual contributors
- toml_parser 1.1.5+spec-1.1.0: Copyright (c) Individual contributors
- toml_writer 1.1.3+spec-1.1.0: Copyright (c) Individual contributors
- typeid 1.0.3: by David Tolnay
- unicode-bidi 0.3.18: Copyright (c) 2015 The Rust Project Developers
- unicode-ident 1.0.27: by David Tolnay
- unicode-normalization 0.1.25: Copyright (c) 2015 The Rust Project Developers
- unicode-properties 0.1.4: Copyright (c) 2015 The Rust Project Developers
- url 2.5.8: Copyright (c) 2013-2025 The rust-url developers
- utf16_iter 1.0.5: Copyright Mozilla Foundation
- utf8_iter 1.0.4: Copyright Mozilla Foundation
- vello_common 0.0.8: Copyright 2020 the Vello Authors
- vello_cpu 0.0.8: Copyright 2020 the Vello Authors
- winnow 1.0.4
- wnaf 0.14.1: Copyright (c) 2018-2025 `group` crate developers; Copyright (c) 2026 RustCrypto Developers
- write16 1.0.0: Copyright Mozilla Foundation
- zerocopy 0.8.63: Copyright 2023 The Fuchsia Authors
- zerocopy-derive 0.8.63: Copyright 2023 The Fuchsia Authors
- zeroize 1.9.1: Copyright (c) 2018-2026 The RustCrypto Project Developers
- zmij 1.0.23: by David Tolnay

#### MIT, form 2 of 8

```
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Used by (77):

- aligned-vec 0.6.4: Copyright (c) 2022 sarah
- boa_ast 0.22.0: by boa-dev
- boa_engine 0.22.0: by boa-dev
- boa_gc 0.22.0: by boa-dev
- boa_interner 0.22.0: by boa-dev
- boa_macros 0.22.0: by boa-dev
- boa_parser 0.22.0: by boa-dev
- boa_string 0.22.0: by boa-dev
- brotli-decompressor 5.0.3: by Daniel Reiter Horn, The Brotli Authors
- chrono 0.4.45
- color 0.3.3
- cow-utils 0.1.3: Copyright (c) 2020 Ingvar Stepanyan
- craft-print 0.1.0
- crc32fast 1.5.2: Copyright (c) 2018 Sam Rijs, Alex Crichton and contributors
- dashmap 6.2.1: Copyright (c) 2019 Acrimon
- EditinPDF: Copyright (c) 2026 EditinPDF contributors
- equator 0.4.2: Copyright (c) 2023 sarah
- equator-macro 0.4.2: Copyright (c) 2023 sarah
- fdeflate 0.3.7: by The image-rs Developers
- half 2.7.1: by Kathryn Long
- image 0.25.10: by The image-rs Developers
- linebender_resource_handle 0.1.1
- lopdf 0.45.0: Copyright (c) 2016 Junfeng Liu
- miniz_oxide 0.8.9: Copyright (c) 2017 Frommi; Copyright (c) 2017-2024 oyvindln; Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC; Copyright 2013-2014 RAD Game Tools and Valve Software
- miniz_oxide 0.8.9: Copyright (c) 2017 Frommi; Copyright (c) 2017-2024 oyvindln; Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC; Copyright 2013-2014 RAD Game Tools and Valve Software
- miniz_oxide 0.9.1: Copyright (c) 2017 Frommi; Copyright (c) 2017-2024 oyvindln; Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC; Copyright 2013-2014 RAD Game Tools and Valve Software
- miniz_oxide 0.9.1: Copyright (c) 2017 Frommi; Copyright (c) 2017-2024 oyvindln; Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC; Copyright 2013-2014 RAD Game Tools and Valve Software
- ocrs 0.13.1: by Robert Knight
- pdfcraft-a11y 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-annot 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-audit 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-compare 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-content 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-cos 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-create 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-crypt 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-edit 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-engine 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-export 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-filters 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-fonts 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-forms 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-geom 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-js 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-measure 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-model 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-ocr 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-optimize 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-organize 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-preflight 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-print 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-redact 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-render 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-sign 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-xfa 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- pdfcraft-xfdf 0.7.1: Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors.
- regress 0.12.0: Copyright (c) 2020 ridiculous_fish
- rten 0.26.0: by Robert Knight
- rten-base 0.26.0: by Robert Knight
- rten-gemm 0.26.0: by Robert Knight
- rten-imageproc 0.26.0: by Robert Knight
- rten-model-file 0.26.0: by Robert Knight
- rten-parallel 0.26.0: by Robert Knight
- rten-shape-inference 0.26.0: by Robert Knight
- rten-simd 0.26.0: by Robert Knight
- rten-tensor 0.26.0: by Robert Knight
- rten-vecmath 0.26.0: by Robert Knight
- simdutf8 0.1.5: by Hans Kratz
- small_btree 0.1.0: by boa-dev
- static_assertions 1.1.0: Copyright (c) 2017 Nikolai Vazquez
- strum 0.28.0: Copyright (c) 2019 Peter Glotfelty
- strum_macros 0.28.0: Copyright (c) 2019 Peter Glotfelty
- tag_ptr 0.1.0: by boa-dev
- tap 1.0.1: Copyright (c) 2017 Elliot Linder
- tiff 0.11.3: Copyright (c) 2018 PistonDevelopers
- zune-core 0.5.3: Copyright (c) zune-image developers
- zune-jpeg 0.5.15: Copyright (c) zune-image developers

#### MIT, form 3 of 8

```
The MIT License (MIT)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

Used by (24):

- base64 0.22.1: Copyright (c) 2015 Alice Maz
- byteorder-lite 0.1.0: Copyright (c) 2015 Andrew Gallant
- color_quant 1.1.0: Copyright (c) 2016 PistonDevelopers
- crossbeam-deque 0.8.8: Copyright (c) 2019 The Crossbeam Project Developers
- crossbeam-epoch 0.9.21: Copyright (c) 2019 The Crossbeam Project Developers
- crossbeam-utils 0.8.23: Copyright (c) 2019 The Crossbeam Project Developers
- ff 0.14.0: Copyright (c) 2017 Sean Bowe
- futures-concurrency 7.7.1: Copyright (c) 2020 Yoshua Wuyts
- gif 0.14.2: Copyright (c) 2015 nwin
- guillotiere 0.7.0: Copyright (c) 2019 Nicolas Silva
- harfrust 0.12.0: Copyright (c) 2020 Yevhenii Reizner; Copyright (c) HarfBuzz developers
- memchr 2.8.3: Copyright (c) 2015 Andrew Gallant
- phf 0.13.1: Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- phf 0.14.0: Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- phf_generator 0.13.1: Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- phf_generator 0.14.0: Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- phf_macros 0.13.1: Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- phf_macros 0.14.0: Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- phf_shared 0.13.1: Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- phf_shared 0.14.0: Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- roxmltree 0.20.0: Copyright (c) 2018 Yevhenii Reizner
- typenum 1.20.1: Copyright (c) 2014 Paho Lurie-Gregg
- weezl 0.1.12: Copyright (c) HeroicKatora 2020
- weezl 0.2.1: Copyright (c) HeroicKatora 2020

#### MIT, form 4 of 8

```
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

Used by (10):

- crypto-primes 0.7.2: Copyright 2022-* Bogdan Opanchuk
- fax 0.2.7: Copyright © 2021 The pdf-rs contributers.
- hayro 0.7.1: Copyright (c) The Hayro Authors
- hayro-ccitt 0.3.0: Copyright (c) The Hayro Authors
- hayro-cmap 0.1.0: Copyright (c) The Hayro Authors
- hayro-interpret 0.7.0: Copyright (c) The Hayro Authors
- hayro-jbig2 0.3.0: Copyright (c) The Hayro Authors
- hayro-jpeg2000 0.3.5: Copyright (c) The Hayro Authors
- hayro-postscript 0.1.0: Copyright (c) The Hayro Authors
- hayro-syntax 0.7.2: Copyright (c) The Hayro Authors

#### MIT, form 5 of 8

```
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice (including the next paragraph) shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

Used by (2):

- bytemuck 1.25.2: Copyright (c) 2019 Daniel "Lokathor" Gee.
- bytemuck_derive 1.12.1: Copyright (c) 2019 Daniel "Lokathor" Gee.

#### MIT, form 6 of 8

```
The MIT License (MIT)

https://github.com/mit-plv/fiat-crypto/blob/master/AUTHORS).

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Used by (1):

- aws-lc-sys 0.46.0: Copyright (c) 2015-2020 the fiat-crypto authors (see

#### MIT, form 7 of 8

```
===============================================================================

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

===============================================================================

Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

Used by (1):

- futures-lite 2.6.1: Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors

#### MIT, form 8 of 8

```
MIT License

Copyright (c) [2021] [Marvin Countryman]

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Used by (1):

- simd-adler32 0.3.10: by Marvin Countryman

### MPL-2.0: Mozilla Public License 2.0

```
Mozilla Public License Version 2.0
==================================

1. Definitions
--------------

1.1. "Contributor"
    means each individual or legal entity that creates, contributes to
    the creation of, or owns Covered Software.

1.2. "Contributor Version"
    means the combination of the Contributions of others (if any) used
    by a Contributor and that particular Contributor's Contribution.

1.3. "Contribution"
    means Covered Software of a particular Contributor.

1.4. "Covered Software"
    means Source Code Form to which the initial Contributor has attached
    the notice in Exhibit A, the Executable Form of such Source Code
    Form, and Modifications of such Source Code Form, in each case
    including portions thereof.

1.5. "Incompatible With Secondary Licenses"
    means

    (a) that the initial Contributor has attached the notice described
        in Exhibit B to the Covered Software; or

    (b) that the Covered Software was made available under the terms of
        version 1.1 or earlier of the License, but not also under the
        terms of a Secondary License.

1.6. "Executable Form"
    means any form of the work other than Source Code Form.

1.7. "Larger Work"
    means a work that combines Covered Software with other material, in
    a separate file or files, that is not Covered Software.

1.8. "License"
    means this document.

1.9. "Licensable"
    means having the right to grant, to the maximum extent possible,
    whether at the time of the initial grant or subsequently, any and
    all of the rights conveyed by this License.

1.10. "Modifications"
    means any of the following:

    (a) any file in Source Code Form that results from an addition to,
        deletion from, or modification of the contents of Covered
        Software; or

    (b) any new file in Source Code Form that contains any Covered
        Software.

1.11. "Patent Claims" of a Contributor
    means any patent claim(s), including without limitation, method,
    process, and apparatus claims, in any patent Licensable by such
    Contributor that would be infringed, but for the grant of the
    License, by the making, using, selling, offering for sale, having
    made, import, or transfer of either its Contributions or its
    Contributor Version.

1.12. "Secondary License"
    means either the GNU General Public License, Version 2.0, the GNU
    Lesser General Public License, Version 2.1, the GNU Affero General
    Public License, Version 3.0, or any later versions of those
    licenses.

1.13. "Source Code Form"
    means the form of the work preferred for making modifications.

1.14. "You" (or "Your")
    means an individual or a legal entity exercising rights under this
    License. For legal entities, "You" includes any entity that
    controls, is controlled by, or is under common control with You. For
    purposes of this definition, "control" means (a) the power, direct
    or indirect, to cause the direction or management of such entity,
    whether by contract or otherwise, or (b) ownership of more than
    fifty percent (50%) of the outstanding shares or beneficial
    ownership of such entity.

2. License Grants and Conditions
--------------------------------

2.1. Grants

Each Contributor hereby grants You a world-wide, royalty-free,
non-exclusive license:

(a) under intellectual property rights (other than patent or trademark)
    Licensable by such Contributor to use, reproduce, make available,
    modify, display, perform, distribute, and otherwise exploit its
    Contributions, either on an unmodified basis, with Modifications, or
    as part of a Larger Work; and

(b) under Patent Claims of such Contributor to make, use, sell, offer
    for sale, have made, import, and otherwise transfer either its
    Contributions or its Contributor Version.

2.2. Effective Date

The licenses granted in Section 2.1 with respect to any Contribution
become effective for each Contribution on the date the Contributor first
distributes such Contribution.

2.3. Limitations on Grant Scope

The licenses granted in this Section 2 are the only rights granted under
this License. No additional rights or licenses will be implied from the
distribution or licensing of Covered Software under this License.
Notwithstanding Section 2.1(b) above, no patent license is granted by a
Contributor:

(a) for any code that a Contributor has removed from Covered Software;
    or

(b) for infringements caused by: (i) Your and any other third party's
    modifications of Covered Software, or (ii) the combination of its
    Contributions with other software (except as part of its Contributor
    Version); or

(c) under Patent Claims infringed by Covered Software in the absence of
    its Contributions.

This License does not grant any rights in the trademarks, service marks,
or logos of any Contributor (except as may be necessary to comply with
the notice requirements in Section 3.4).

2.4. Subsequent Licenses

No Contributor makes additional grants as a result of Your choice to
distribute the Covered Software under a subsequent version of this
License (see Section 10.2) or under the terms of a Secondary License (if
permitted under the terms of Section 3.3).

2.5. Representation

Each Contributor represents that the Contributor believes its
Contributions are its original creation(s) or it has sufficient rights
to grant the rights to its Contributions conveyed by this License.

2.6. Fair Use

This License is not intended to limit any rights You have under
applicable copyright doctrines of fair use, fair dealing, or other
equivalents.

2.7. Conditions

Sections 3.1, 3.2, 3.3, and 3.4 are conditions of the licenses granted
in Section 2.1.

3. Responsibilities
-------------------

3.1. Distribution of Source Form

All distribution of Covered Software in Source Code Form, including any
Modifications that You create or to which You contribute, must be under
the terms of this License. You must inform recipients that the Source
Code Form of the Covered Software is governed by the terms of this
License, and how they can obtain a copy of this License. You may not
attempt to alter or restrict the recipients' rights in the Source Code
Form.

3.2. Distribution of Executable Form

If You distribute Covered Software in Executable Form then:

(a) such Covered Software must also be made available in Source Code
    Form, as described in Section 3.1, and You must inform recipients of
    the Executable Form how they can obtain a copy of such Source Code
    Form by reasonable means in a timely manner, at a charge no more
    than the cost of distribution to the recipient; and

(b) You may distribute such Executable Form under the terms of this
    License, or sublicense it under different terms, provided that the
    license for the Executable Form does not attempt to limit or alter
    the recipients' rights in the Source Code Form under this License.

3.3. Distribution of a Larger Work

You may create and distribute a Larger Work under terms of Your choice,
provided that You also comply with the requirements of this License for
the Covered Software. If the Larger Work is a combination of Covered
Software with a work governed by one or more Secondary Licenses, and the
Covered Software is not Incompatible With Secondary Licenses, this
License permits You to additionally distribute such Covered Software
under the terms of such Secondary License(s), so that the recipient of
the Larger Work may, at their option, further distribute the Covered
Software under the terms of either this License or such Secondary
License(s).

3.4. Notices

You may not remove or alter the substance of any license notices
(including copyright notices, patent notices, disclaimers of warranty,
or limitations of liability) contained within the Source Code Form of
the Covered Software, except that You may alter any license notices to
the extent required to remedy known factual inaccuracies.

3.5. Application of Additional Terms

You may choose to offer, and to charge a fee for, warranty, support,
indemnity or liability obligations to one or more recipients of Covered
Software. However, You may do so only on Your own behalf, and not on
behalf of any Contributor. You must make it absolutely clear that any
such warranty, support, indemnity, or liability obligation is offered by
You alone, and You hereby agree to indemnify every Contributor for any
liability incurred by such Contributor as a result of warranty, support,
indemnity or liability terms You offer. You may include additional
disclaimers of warranty and limitations of liability specific to any
jurisdiction.

4. Inability to Comply Due to Statute or Regulation
---------------------------------------------------

If it is impossible for You to comply with any of the terms of this
License with respect to some or all of the Covered Software due to
statute, judicial order, or regulation then You must: (a) comply with
the terms of this License to the maximum extent possible; and (b)
describe the limitations and the code they affect. Such description must
be placed in a text file included with all distributions of the Covered
Software under this License. Except to the extent prohibited by statute
or regulation, such description must be sufficiently detailed for a
recipient of ordinary skill to be able to understand it.

5. Termination
--------------

5.1. The rights granted under this License will terminate automatically
if You fail to comply with any of its terms. However, if You become
compliant, then the rights granted under this License from a particular
Contributor are reinstated (a) provisionally, unless and until such
Contributor explicitly and finally terminates Your grants, and (b) on an
ongoing basis, if such Contributor fails to notify You of the
non-compliance by some reasonable means prior to 60 days after You have
come back into compliance. Moreover, Your grants from a particular
Contributor are reinstated on an ongoing basis if such Contributor
notifies You of the non-compliance by some reasonable means, this is the
first time You have received notice of non-compliance with this License
from such Contributor, and You become compliant prior to 30 days after
Your receipt of the notice.

5.2. If You initiate litigation against any entity by asserting a patent
infringement claim (excluding declaratory judgment actions,
counter-claims, and cross-claims) alleging that a Contributor Version
directly or indirectly infringes any patent, then the rights granted to
You by any and all Contributors for the Covered Software under Section
2.1 of this License shall terminate.

5.3. In the event of termination under Sections 5.1 or 5.2 above, all
end user license agreements (excluding distributors and resellers) which
have been validly granted by You or Your distributors under this License
prior to termination shall survive termination.

************************************************************************
*                                                                      *
*  6. Disclaimer of Warranty                                           *
*  -------------------------                                           *
*                                                                      *
*  Covered Software is provided under this License on an "as is"       *
*  basis, without warranty of any kind, either expressed, implied, or  *
*  statutory, including, without limitation, warranties that the       *
*  Covered Software is free of defects, merchantable, fit for a        *
*  particular purpose or non-infringing. The entire risk as to the     *
*  quality and performance of the Covered Software is with You.        *
*  Should any Covered Software prove defective in any respect, You     *
*  (not any Contributor) assume the cost of any necessary servicing,   *
*  repair, or correction. This disclaimer of warranty constitutes an   *
*  essential part of this License. No use of any Covered Software is   *
*  authorized under this License except under this disclaimer.         *
*                                                                      *
************************************************************************

************************************************************************
*                                                                      *
*  7. Limitation of Liability                                          *
*  --------------------------                                          *
*                                                                      *
*  Under no circumstances and under no legal theory, whether tort      *
*  (including negligence), contract, or otherwise, shall any           *
*  Contributor, or anyone who distributes Covered Software as          *
*  permitted above, be liable to You for any direct, indirect,         *
*  special, incidental, or consequential damages of any character      *
*  including, without limitation, damages for lost profits, loss of    *
*  goodwill, work stoppage, computer failure or malfunction, or any    *
*  and all other commercial damages or losses, even if such party      *
*  shall have been informed of the possibility of such damages. This   *
*  limitation of liability shall not apply to liability for death or   *
*  personal injury resulting from such party's negligence to the       *
*  extent applicable law prohibits such limitation. Some               *
*  jurisdictions do not allow the exclusion or limitation of           *
*  incidental or consequential damages, so this exclusion and          *
*  limitation may not apply to You.                                    *
*                                                                      *
************************************************************************

8. Litigation
-------------

Any litigation relating to this License may be brought only in the
courts of a jurisdiction where the defendant maintains its principal
place of business and such litigation shall be governed by laws of that
jurisdiction, without reference to its conflict-of-law provisions.
Nothing in this Section shall prevent a party's ability to bring
cross-claims or counter-claims.

9. Miscellaneous
----------------

This License represents the complete agreement concerning the subject
matter hereof. If any provision of this License is held to be
unenforceable, such provision shall be reformed only to the extent
necessary to make it enforceable. Any law or regulation which provides
that the language of a contract shall be construed against the drafter
shall not be used to construe this License against a Contributor.

10. Versions of the License
---------------------------

10.1. New Versions

Mozilla Foundation is the license steward. Except as provided in Section
10.3, no one other than the license steward has the right to modify or
publish new versions of this License. Each version will be given a
distinguishing version number.

10.2. Effect of New Versions

You may distribute the Covered Software under the terms of the version
of the License under which You originally received the Covered Software,
or under the terms of any subsequent version published by the license
steward.

10.3. Modified Versions

If you create software not governed by this License, and you want to
create a new license for such software, you may create and use a
modified version of this License if you rename the license and remove
any references to the name of the license steward (except to note that
such modified license differs from this License).

10.4. Distributing Source Code Form that is Incompatible With Secondary
Licenses

If You choose to distribute Source Code Form that is Incompatible With
Secondary Licenses under the terms of this version of the License, the
notice described in Exhibit B of this License must be attached.

Exhibit A - Source Code Form License Notice
-------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at https://mozilla.org/MPL/2.0/.

If it is not possible or desirable to put the notice in a particular
file, then You may include the notice in a location (such as a LICENSE
file in a relevant directory) where a recipient would be likely to look
for such a notice.

You may add additional accurate notices of copyright ownership.

Exhibit B - "Incompatible With Secondary Licenses" Notice
---------------------------------------------------------

  This Source Code Form is "Incompatible With Secondary Licenses", as
  defined by the Mozilla Public License, v. 2.0.
```

Used by (6):

- uniffi 0.32.2
- uniffi_core 0.32.2
- uniffi_internal_macros 0.32.2
- uniffi_macros 0.32.2
- uniffi_meta 0.32.2
- uniffi_pipeline 0.32.2

### OFL-1.1: SIL Open Font License 1.1

#### OFL-1.1, form 1 of 2

```
This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
http://scripts.sil.org/OFL

-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

Used by (1):

- Dancing Script (font): Copyright 2016 The Dancing Script Project Authors (https://github.com/googlefonts/DancingScript), with Reserved Font Name 'Dancing Script'.

#### OFL-1.1, form 2 of 2

```
This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
http://scripts.sil.org/OFL

-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION AND CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

Used by (1):

- Inter Regular (font): Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter)

### Unicode-3.0: Unicode License v3

#### Unicode-3.0, form 1 of 2

```
UNICODE LICENSE V3

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.

SPDX-License-Identifier: Unicode-3.0

—

Portions of ICU4X may have been adapted from ICU4C and/or ICU4J.
ICU 1.8.1 to ICU 57.1 © 1995-2016 International Business Machines Corporation and others.
```

Used by (18):

- icu_collections 2.3.0: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- icu_locale_core 2.3.0: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- icu_normalizer 2.3.0: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- icu_normalizer_data 2.3.0: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- icu_properties 2.3.0: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- icu_properties_data 2.3.0: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- icu_provider 2.3.1: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- litemap 0.8.3: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- potential_utf 0.1.6: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- tinystr 0.8.4: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- writeable 0.6.4: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- yoke 0.8.3: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- yoke-derive 0.8.4: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- zerofrom 0.1.8: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- zerofrom-derive 0.1.8: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- zerotrie 0.2.5: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- zerovec 0.11.8: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.
- zerovec-derive 0.11.6: COPYRIGHT AND PERMISSION NOTICE; Copyright © 2020-2024 Unicode, Inc.

#### Unicode-3.0, form 2 of 2

```
UNICODE LICENSE V3

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
```

Used by (1):

- unicode-ident 1.0.27: COPYRIGHT AND PERMISSION NOTICE; Copyright © 1991-2023 Unicode, Inc.

### Zlib: zlib License

```
This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use of
this software.

Permission is granted to anyone to use this software for any purpose, including
commercial applications, and to alter it and redistribute it freely, subject to
the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim
    that you wrote the original software. If you use this software in a product,
    an acknowledgment in the product documentation would be appreciated but is
    not required.

2. Altered source versions must be plainly marked as such, and must not be
    misrepresented as being the original software.

3. This notice may not be removed or altered from any source distribution.
```

Used by (1):

- foldhash 0.2.0: Copyright (c) 2024 Orson Peters
