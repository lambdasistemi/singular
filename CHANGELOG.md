# Changelog

## [0.7.0](https://github.com/lambdasistemi/singular/compare/v0.6.1...v0.7.0) (2026-09-19)


### Features

* [#157](https://github.com/lambdasistemi/singular/issues/157) D-BOOT carrier, and X1's harness on the derived pins ([9cba521](https://github.com/lambdasistemi/singular/commit/9cba521fdf244b12bf508ad83c01b193866411cd))
* [#157](https://github.com/lambdasistemi/singular/issues/157) derive the obligations a registry-mode edge owes a fold ([1b44867](https://github.com/lambdasistemi/singular/commit/1b44867a8647f3df4a54005fac24209438207e0d))
* [#157](https://github.com/lambdasistemi/singular/issues/157) registry-mode encodings and the four derived pins (D-BOOT) ([f71c0d2](https://github.com/lambdasistemi/singular/commit/f71c0d25a87a0925f7ad41ce20375e3f361958ad))
* [#157](https://github.com/lambdasistemi/singular/issues/157) the blueprint reads a fixed tuple, and X1's local rows execute ([a13b855](https://github.com/lambdasistemi/singular/commit/a13b855d1e786346089f10cffd7527205fbc8931))
* [#157](https://github.com/lambdasistemi/singular/issues/157) the generic rows fold real edges ([75dfad5](https://github.com/lambdasistemi/singular/commit/75dfad52b771a2332f79cb2f75943ba5192c48d6))
* **173:** admit the open application's approvals, and sweep the witness move ([6bff250](https://github.com/lambdasistemi/singular/commit/6bff2502c1499060bc6edb1ed80b4f92bbc3ab2b))
* **173:** boot the open registry from its own blueprint, with no naming input ([0122cba](https://github.com/lambdasistemi/singular/commit/0122cba09a76245e839801305e459fb286f600c0))
* **173:** fold insertActive to a named wallet, and mirror each landed fold ([7944105](https://github.com/lambdasistemi/singular/commit/7944105025590cb3bbf551ca05715ebb9db0171a))
* **173:** give a receipt somewhere to record an insertActive observation ([d64f895](https://github.com/lambdasistemi/singular/commit/d64f8953700958d11f0cf6bccf607413c488b7c2))
* **173:** model insertActive at transaction level and key the fold's mint guard ([bc5852b](https://github.com/lambdasistemi/singular/commit/bc5852baa799d763804593890c92c447e47a70c3))
* **173:** refuse the duplicate insert instead of crashing on it ([63f36c8](https://github.com/lambdasistemi/singular/commit/63f36c804b65266001a0a8675e0b6ef3c734970c))
* **173:** ship insert-active in the release archive and run it from there ([f5064f0](https://github.com/lambdasistemi/singular/commit/f5064f06dc0b90902e59bbb223b821f1d39de686))
* execute the insertActive conformance row ([e88e306](https://github.com/lambdasistemi/singular/commit/e88e3069f4d4a4ceb447e4cc3a85b2a59a2e1749))
* implement registry-mode Aiken cage ([#157](https://github.com/lambdasistemi/singular/issues/157)) ([240ede1](https://github.com/lambdasistemi/singular/commit/240ede16b37c0dccf797c8c0e222e3d782331803))
* **model:** complete all seven edge inversions in both directions ([792b5ad](https://github.com/lambdasistemi/singular/commit/792b5ad66fff8eae0ad80ea4c989f2653664f8f6))
* **model:** prove L1 and restate fold_batch_cons over the inner fold ([1319bc4](https://github.com/lambdasistemi/singular/commit/1319bc489bcf7c4b99d9a7534d378717e144d9e8))
* **model:** prove P1, the read facts and the fold refusal ([a047c9e](https://github.com/lambdasistemi/singular/commit/a047c9e4ee9caaf2f983d51e6efffc9393a5e00a))
* **model:** prove S1/S3/W1/W2/W4 and the tree-edge inversions ([bbacfae](https://github.com/lambdasistemi/singular/commit/bbacfae9ac3d46845d32ab4c9655bb45b665d78e))
* **model:** prove S2 permanence, O1 occupancy and T1 termination ([7ee6ecb](https://github.com/lambdasistemi/singular/commit/7ee6ecb07551eefc2eae887197a3171b4fb7cb0d))
* **model:** prove the lifecycle statements; the model is sorry-free ([567e84f](https://github.com/lambdasistemi/singular/commit/567e84fb67ebae1609e3609b9aefc07b33b080e3))
* **model:** prove the naming instance statements (NM4, R-NM4, NM5) ([a676001](https://github.com/lambdasistemi/singular/commit/a67600184010d883909fa1ac26f29e76fdc7d392))
* **model:** prove the occupancy converse and the terminal-mint provenance ([0c47025](https://github.com/lambdasistemi/singular/commit/0c470254ef14307506fc1746b2acacc3a1587283))
* **model:** prove the two workhorse lemmas the statements rest on ([565f82d](https://github.com/lambdasistemi/singular/commit/565f82d79a679671aacebdab0f9d462cae8cd16b))
* **model:** prove the wire statements, byte-exactly ([cf48231](https://github.com/lambdasistemi/singular/commit/cf48231ef088a4d119f0aa0cee36c93b63d8db85))
* **model:** prove W3, the plurality of the terminal witness ([be66a50](https://github.com/lambdasistemi/singular/commit/be66a50868893aeb95f3091bd490dded71e91db2))
* **model:** regenerate the manifests, corpora and theorem page; just model green ([3917517](https://github.com/lambdasistemi/singular/commit/39175170e42db024e2fd629f6eff14a0e0c3117d))
* **simulator:** transcribe the registry model; replay naming and its lifecycle ([5bbfba1](https://github.com/lambdasistemi/singular/commit/5bbfba11895a645083251c12ea4f455b08cea997))


### Fixes

* [#157](https://github.com/lambdasistemi/singular/issues/157) authenticate the coupled transitions the audit found unbound ([ca8611f](https://github.com/lambdasistemi/singular/commit/ca8611fa4703f9cd92550516a42031b9f2447551))
* [#157](https://github.com/lambdasistemi/singular/issues/157) bind the custody fold to its own registry, and fit the boot ([de430ff](https://github.com/lambdasistemi/singular/commit/de430ffc1711ff5f7b95d8a19fcebe3ee808de5b))
* [#157](https://github.com/lambdasistemi/singular/issues/157) carry the retired encodings through the derived executables ([7b76227](https://github.com/lambdasistemi/singular/commit/7b76227d184ee830b14dd4b04dfb77b4d4053946))
* [#157](https://github.com/lambdasistemi/singular/issues/157) CG11, CG12 and CG19's bookings are edges ([f22cc37](https://github.com/lambdasistemi/singular/commit/f22cc3795c7c09a4af59f8343dc6b6c88a0ba27a))
* [#157](https://github.com/lambdasistemi/singular/issues/157) duties follow the action, and the row folds discharge them ([9edcb29](https://github.com/lambdasistemi/singular/commit/9edcb292baf7225680dbb8cd90c603e3348d05a1))
* [#157](https://github.com/lambdasistemi/singular/issues/157) every issue-70 request is a booking, and the folds balance it ([6c5872f](https://github.com/lambdasistemi/singular/commit/6c5872fb754d2ccab0a70c92017191939a2b746a))
* [#157](https://github.com/lambdasistemi/singular/issues/157) the custody rule binds by token, not by address ([fdcf841](https://github.com/lambdasistemi/singular/commit/fdcf841c54c79c242210cefebc8c672a933100c2))
* [#157](https://github.com/lambdasistemi/singular/issues/157) the generic session funds, seeds and boots under registry mode ([c9ebd0f](https://github.com/lambdasistemi/singular/commit/c9ebd0fb63d0a933abf0232e9ed6144a26c922e6))
* [#157](https://github.com/lambdasistemi/singular/issues/157) the generic session's cages publish once and fund cleanly ([fcfc085](https://github.com/lambdasistemi/singular/commit/fcfc08558541b13e78f1be24c8cc1d9efed920ac))
* [#157](https://github.com/lambdasistemi/singular/issues/157) the issue-70 rows book edges too ([9461344](https://github.com/lambdasistemi/singular/commit/9461344f11836797be889d5c9ad1f92441bb9fc1))
* [#157](https://github.com/lambdasistemi/singular/issues/157) the wallet sweep leaves the CA seed alone ([1dac2d4](https://github.com/lambdasistemi/singular/commit/1dac2d490d8a2638fa8f51822ae7401913fd59d4))
* **157:** bind the E2E rows and the journey to real registry edges ([dfe06f1](https://github.com/lambdasistemi/singular/commit/dfe06f198f452074502df352f062a361e93180de))
* **157:** drop the deleted consumer hook from the CG19 control binding ([2da66f4](https://github.com/lambdasistemi/singular/commit/2da66f4ac10b9e31e7c56566c12be97d4e7ce84e))
* **157:** find Fork [#81](https://github.com/lambdasistemi/singular/issues/81)'s state UTxO by its policy token ([b0ccdd8](https://github.com/lambdasistemi/singular/commit/b0ccdd8a7c8d0a0bcb94f81bd43cd2683267119c))
* **157:** re-cut CG19 against the interface's routing, no hook ([2006f5c](https://github.com/lambdasistemi/singular/commit/2006f5c146656dec1f34a1b4f65d4564443b285d))
* **157:** read the fold's script identities from its reference inputs ([c7c8ddd](https://github.com/lambdasistemi/singular/commit/c7c8dddaf2e165566e74ca1f52f5919ff2eea1b1))
* **173:** build the transaction, bridge the keyed witness, key the JS fold ([854f56f](https://github.com/lambdasistemi/singular/commit/854f56fd3e2765ef19270b3a40398d53092748f2))
* **173:** read a validator's parameter count instead of writing it down ([3587bcb](https://github.com/lambdasistemi/singular/commit/3587bcb2fd6813d5e2ba31e2612a2d974a6e6234))
* **ci:** cover Lean and HTML registry rename inputs ([d542c9f](https://github.com/lambdasistemi/singular/commit/d542c9ff2b1df2eeea5739b6128d513ba6df668b))
* **ci:** cover Lean and HTML registry rename inputs ([28a6819](https://github.com/lambdasistemi/singular/commit/28a6819deafab87a559182a62e98b4a4fe6e572e))
* **coverage,wire:** adopt the registry-mode inventory in both protected judges ([5422fe0](https://github.com/lambdasistemi/singular/commit/5422fe0b945b1b3780d109fbe4734974c8cf44ca))
* make rename-registry control pass on main ([8c5e053](https://github.com/lambdasistemi/singular/commit/8c5e053018aa297d22e5f2635a6164fc7a7cd820))
* **model:** build the naming axiom gate, and check that every module is reachable ([5ed6df8](https://github.com/lambdasistemi/singular/commit/5ed6df8e5332aa92df0dce1feae0ed07f761352f))
* **model:** split retirement request completion ([f70af8a](https://github.com/lambdasistemi/singular/commit/f70af8a97dd44c581f53aa69a6f89714d2eff708))
* **model:** split retirement request completion ([09ba0c9](https://github.com/lambdasistemi/singular/commit/09ba0c9afd7b64ea54fb07dd381ee0fdaa51eff1))
* preserve naming record asset shape ([1bee7ca](https://github.com/lambdasistemi/singular/commit/1bee7ca1d069737c81d441d1e895beff32392886))
* preserve naming record asset shape ([5acd8d2](https://github.com/lambdasistemi/singular/commit/5acd8d2fffe96ca3f18bf9f2067834d3c7ffd0b7))
* **tools:** test the tree under test and survive deleted rename targets ([d0fef25](https://github.com/lambdasistemi/singular/commit/d0fef25d6f78a3188b7d55359dd7d51d54d1a297))


### Documentation

* [#157](https://github.com/lambdasistemi/singular/issues/157) CG19 says what it now does ([a32d2d9](https://github.com/lambdasistemi/singular/commit/a32d2d93313283472d16e06a4d71b14d7faec36d))
* [#157](https://github.com/lambdasistemi/singular/issues/157) mandate — D-BOOT carrier: CageParts carries the four derived pins; Deployment.hs and Register.hs in the fence; consumer registration deleted ([cb6b46e](https://github.com/lambdasistemi/singular/commit/cb6b46e61c8a3afe70ff834a653c6c5446765a89))
* [#157](https://github.com/lambdasistemi/singular/issues/157) mandate — D-BOOT: the four pins are derived at genesis; X1 executable stays here with the five files the encodings force ([56c2863](https://github.com/lambdasistemi/singular/commit/56c2863f339a409b8b0312be283d9efe46653687))
* [#157](https://github.com/lambdasistemi/singular/issues/157) mandate — D-DEST encoding is Aiken's fixed tuple; Blueprint.hs parses it (eighth file in the fence) ([b5df2b0](https://github.com/lambdasistemi/singular/commit/b5df2b082d3b864859068b5203d653598144306c))
* [#157](https://github.com/lambdasistemi/singular/issues/157) mandate — N10 excludes the read: Read(0x02) on a terminal leaf is accepted ([44ecdd7](https://github.com/lambdasistemi/singular/commit/44ecdd7955609ab7d8524eca3757c5b712c5896c))
* [#157](https://github.com/lambdasistemi/singular/issues/157) mandate — retirement gated on the recovery key, deposits returned, known weaknesses stated (want-ledger R1–R4) ([cd43313](https://github.com/lambdasistemi/singular/commit/cd43313940ee021d06eeb8f0b171df9a160ec445))
* [#157](https://github.com/lambdasistemi/singular/issues/157) mandate — X3: the existing journeys are re-cut here; main is never red on a journey job ([d0bef8d](https://github.com/lambdasistemi/singular/commit/d0bef8df1017f7d956c494431ab3c0059132a0d3))
* **157:** move NYA journeys to epic 174 ([54503cc](https://github.com/lambdasistemi/singular/commit/54503cc4039aa7fdd3c7fdd75cb681e4a7b3d86e))
* **157:** record registry journey and CG19 routing ([a298c3f](https://github.com/lambdasistemi/singular/commit/a298c3fd00be6576389f87ab779e8e921d503d3d))
* **157:** record request residual and journey ownership ([156931d](https://github.com/lambdasistemi/singular/commit/156931dcc73c7b1e1519cc5eca5becc9d74d6b1f))
* **157:** record serialization row split ([0caa84f](https://github.com/lambdasistemi/singular/commit/0caa84f78d0010eb39a0373128ade57a3162ec7e))
* **173:** apply slicing audit recut ([b446626](https://github.com/lambdasistemi/singular/commit/b44662631e6869f2f01c904a119e8a67897fa19f))
* **173:** define the insert-active vertical slice ([3401083](https://github.com/lambdasistemi/singular/commit/3401083785ae84e11de804fd7269cb181a0c16ef))
* **173:** describe what the insertActive devnet spec actually does ([805f0c2](https://github.com/lambdasistemi/singular/commit/805f0c2a7040aa572eb76c21c6a028b157f29a2c))
* add the speech companions the planning pages owe ([71b114d](https://github.com/lambdasistemi/singular/commit/71b114da5c88d5eb4edc3f910aaf2cb9a77820fc))
* apply the operator's specification findings (packet v3) ([9668eee](https://github.com/lambdasistemi/singular/commit/9668eee4b20f9eb87e31ec9c9ed5ea77e82529c7))
* carry two operator rulings into the slice-A mandate ([fac6645](https://github.com/lambdasistemi/singular/commit/fac6645c78dd3df4c4cdf7701a8359b3e27e1c6d))
* define insertActive conformance mandate ([0d5282b](https://github.com/lambdasistemi/singular/commit/0d5282be0e6c52fd9706a5cdde419fce016e5256))
* mark insertActive conformance as pending ([01f14f2](https://github.com/lambdasistemi/singular/commit/01f14f2f9f4057af49c018e1702a4301132ec47c))
* plan [#157](https://github.com/lambdasistemi/singular/issues/157) — the cage in registry mode replaces consumer.ak ([6db37a0](https://github.com/lambdasistemi/singular/commit/6db37a092be065b8510b3e5de97a072b943fb85b))
* plan the registry-mode Lean model ([3c91180](https://github.com/lambdasistemi/singular/commit/3c91180d828050806f5d1445ad412f304215df1d))
* recompile the [#156](https://github.com/lambdasistemi/singular/issues/156) mandate as two slices under ruling A-001 ([5db006e](https://github.com/lambdasistemi/singular/commit/5db006eff362589e5c3f7a9cdf5a03f860e8d297))
* record frozen insertActive gate ([1bdb437](https://github.com/lambdasistemi/singular/commit/1bdb437f3f94ebdd907dcb342289bc0883282252))
* record insertActive ticket readiness ([38e311a](https://github.com/lambdasistemi/singular/commit/38e311a2794c7058986614485700f1429a2b4416))
* record the theorem-page finding as two mandate obligations ([97e2f31](https://github.com/lambdasistemi/singular/commit/97e2f3118884c050379733ee9bc90db1c1f1205b))
* require the oracle observation surface the repaired gate reads ([3101222](https://github.com/lambdasistemi/singular/commit/3101222d29b413a40b20eebb4587611e137bc359))
* rewrite the model ledger and mutation ledger for registry mode ([941c6d2](https://github.com/lambdasistemi/singular/commit/941c6d24289c4e24858eb3c99cb56384e9f2f14b))
* **spec:** add root CI rename repair task ([aabd291](https://github.com/lambdasistemi/singular/commit/aabd29137055d8fad9954e75b415aa436bd78181))
* speech for the regenerated theorem manifest page ([7362ef1](https://github.com/lambdasistemi/singular/commit/7362ef155e6db5dda644b77c1c771098fa6e9f20))


### Automation

* **157:** retire the NYA application journey jobs ([a488924](https://github.com/lambdasistemi/singular/commit/a4889241079ba2052803817774e1ed2657446d70))
* **157:** split serialization rows by edge ([abcb690](https://github.com/lambdasistemi/singular/commit/abcb69037960648cacdfdb11b3508290d03f6ddb)), closes [#157](https://github.com/lambdasistemi/singular/issues/157)

## [0.6.1](https://github.com/lambdasistemi/singular/compare/v0.6.0...v0.6.1) (2026-09-15)


### Fixes

* classify a pending request by phase before resuming it ([58dae70](https://github.com/lambdasistemi/singular/commit/58dae70515a70c69e9d2dca2bc63dfc8762c7542))
* classify a pending request by phase before resuming it ([9ae4d3f](https://github.com/lambdasistemi/singular/commit/9ae4d3fcc6540fac10ce58f412544ebb2e3436a8))
* create the evidence directory before the Koios echo writes into it ([fceba9c](https://github.com/lambdasistemi/singular/commit/fceba9c3f2c4f903e72145e51155cc604c1d6e4b))
* create the evidence directory before the Koios echo writes into it ([447b484](https://github.com/lambdasistemi/singular/commit/447b4844cee43657751d87b316378c3cf6fee4cc))
* deploy window parameters; complete retirement inside its window ([c27c3dd](https://github.com/lambdasistemi/singular/commit/c27c3dd8ba5aac84732067deb996abd633c88202))
* deploy window parameters; complete retirement inside its window ([1580d32](https://github.com/lambdasistemi/singular/commit/1580d32c151266f7fb342ae8548a4dc6677c7231))
* echo every register submission to Koios; gate resume on attached mode ([84d9b17](https://github.com/lambdasistemi/singular/commit/84d9b17287481f1ba1cf6df1a4b51eab335a2537))
* fund public naming lifecycles from live protocol parameters ([6ab1093](https://github.com/lambdasistemi/singular/commit/6ab1093367e00290a4b74638f03f5ef44b3137e6))
* fund public naming lifecycles from live protocol parameters ([345658d](https://github.com/lambdasistemi/singular/commit/345658df4231bc2623e77c11ba50d86add03359c))
* preserve reserved lifecycle inputs during request funding ([e4ae941](https://github.com/lambdasistemi/singular/commit/e4ae94111e02e87f766b75a220c1bad97a76c2ba))
* **release:** publish version changes and usable archive instructions ([454aec3](https://github.com/lambdasistemi/singular/commit/454aec3858f0aa029d93928f09b5c4447bf49894))
* **release:** publish version changes and usable archive instructions ([1f85239](https://github.com/lambdasistemi/singular/commit/1f85239ddb5df15b9f0d5e9acd9865ad2f02892d))
* resume a pending claim and bound confirmation polls by validity window ([4657615](https://github.com/lambdasistemi/singular/commit/46576154450dc1dab70dda92a9d9f0ea7519118d))
* resume a pending claim and bound confirmation polls by validity window ([b1c453f](https://github.com/lambdasistemi/singular/commit/b1c453f1f57197e58012c6677d657ff44ee47514))
* run the custody refusal probes before completion on devnet ([01602a4](https://github.com/lambdasistemi/singular/commit/01602a4881747464b3b83f2547e018dfe6b168d9))
* treat an unforecastable completion deadline as not-yet-passed ([5808d77](https://github.com/lambdasistemi/singular/commit/5808d77e2c19a26db605eae9dbd8aabff68c933c))


### Documentation

* **specs:** repair 122 record per audit-123 FAIL (gist link, coverage residual) ([6306c95](https://github.com/lambdasistemi/singular/commit/6306c952acf292afa656b88ddcb741c72cd3d328))
* **specs:** retroactive record for PR [#106](https://github.com/lambdasistemi/singular/issues/106) persistent deployment ([b63055c](https://github.com/lambdasistemi/singular/commit/b63055ca0f510be7deb9ba7d5376204b139a6cea))
* **specs:** retroactive record for PR [#106](https://github.com/lambdasistemi/singular/issues/106) persistent deployment ([25c99a1](https://github.com/lambdasistemi/singular/commit/25c99a11fe8442dc0189293ee830753ca5e0ac87))
* **specs:** retroactive record for PR [#109](https://github.com/lambdasistemi/singular/issues/109) rename script gate ([76105ca](https://github.com/lambdasistemi/singular/commit/76105ca6b8fa9d500a363618611b82cb7f6efc60))
* **specs:** retroactive record for PR [#109](https://github.com/lambdasistemi/singular/issues/109) rename script gate ([de8f957](https://github.com/lambdasistemi/singular/commit/de8f9577934bcca780fddd7775f81ce43de2ea7d))
* **specs:** retroactive record for PR [#112](https://github.com/lambdasistemi/singular/issues/112) representative name ([7c5618a](https://github.com/lambdasistemi/singular/commit/7c5618a0ac7759656c90a098f7c3cf56a55aafbb))
* **specs:** retroactive record for PR [#112](https://github.com/lambdasistemi/singular/issues/112) representative name ([745eaae](https://github.com/lambdasistemi/singular/commit/745eaae9a7d8f9aabdc2e46ad63ac887829b5037))
* **specs:** retroactive record for PR [#121](https://github.com/lambdasistemi/singular/issues/121) release notes ([bb06044](https://github.com/lambdasistemi/singular/commit/bb060443e8c0812a6528b98bc83b8f5f690b854d))
* **specs:** retroactive record for PR [#121](https://github.com/lambdasistemi/singular/issues/121) release notes ([9734298](https://github.com/lambdasistemi/singular/commit/97342984b40cd64dde662e92db6241fc4737c498))
* **specs:** retroactive record for PR [#122](https://github.com/lambdasistemi/singular/issues/122) lifecycle funding ([7fbbb12](https://github.com/lambdasistemi/singular/commit/7fbbb124cb7d78ba7e4f305942a02d2c96ff01ab))
* **specs:** retroactive record for PR [#122](https://github.com/lambdasistemi/singular/issues/122) lifecycle funding ([437611a](https://github.com/lambdasistemi/singular/commit/437611aab46ffdfd7fb19151b353e2ccac91c9b4))
* **specs:** speech companions for the 122 lifecycle funding record ([b8586ee](https://github.com/lambdasistemi/singular/commit/b8586ee1241fcdeb07fce5f47f9fcbbce50d05e3))

## [0.6.0](https://github.com/lambdasistemi/singular/compare/v0.5.0...v0.6.0) (2026-09-14)


### Features

* a deployment manifest, and the deploy and verify commands ([c86bd3f](https://github.com/lambdasistemi/singular/commit/c86bd3f2b4134aa78977addf8be67411d13540ab)), closes [#102](https://github.com/lambdasistemi/singular/issues/102)
* a devnet check that the attach path boots and publishes nothing ([7ab2e56](https://github.com/lambdasistemi/singular/commit/7ab2e5665106d064cf3380283899504ed02af06d)), closes [#102](https://github.com/lambdasistemi/singular/issues/102)
* a persistent deployment — manifest, verifier, deploy command ([f558d0e](https://github.com/lambdasistemi/singular/commit/f558d0e8fc916eef494fffcef09cfe2ac5582b8e))
* bind representative policies to their registry ([0a75b76](https://github.com/lambdasistemi/singular/commit/0a75b764d17f79893e64facfa79567df865f0d53))
* deploy and verify registry-bound representative policies ([d796fda](https://github.com/lambdasistemi/singular/commit/d796fdabff43be7f74045f242754f6e9423aa58f))
* derive representative names from spelling ([b4a36ea](https://github.com/lambdasistemi/singular/commit/b4a36eaf72d8a355d9048a00081a8f999c195e27))
* derive representatives from spelling and witness retirement registry ([bea5e36](https://github.com/lambdasistemi/singular/commit/bea5e36a3ce5d823575a11417b0c5da7b0ffb18c))
* the naming runners attach to a recorded deployment ([85bed5a](https://github.com/lambdasistemi/singular/commit/85bed5ae0a02ce79380de1d404d868089f30bbc3)), closes [#102](https://github.com/lambdasistemi/singular/issues/102)


### Fixes

* **ci:** keep checks out of the build gate ([279d141](https://github.com/lambdasistemi/singular/commit/279d14191c892218719235a0b031668eb28a79eb))
* **ci:** run every required check on all pull requests ([7e49825](https://github.com/lambdasistemi/singular/commit/7e49825a6c6a52dde674ef57d3052d917a923776))
* count reference scripts at every journey publisher ([acd3ab8](https://github.com/lambdasistemi/singular/commit/acd3ab8cf132c60beb51a3322ff273e57d59dd6c))
* create the trie an attaching run needs, and give the check its own chain ([be2280e](https://github.com/lambdasistemi/singular/commit/be2280efa32faec02dabdb5c9398502ad01950f0)), closes [#102](https://github.com/lambdasistemi/singular/issues/102)
* exercise registry refusal and follow accepted retirement evidence ([900936f](https://github.com/lambdasistemi/singular/commit/900936f948441c9dbbbcd48c08660bdf065c629a))
* observe confirmations and reuse registered credentials ([f0c6506](https://github.com/lambdasistemi/singular/commit/f0c65061cbd7ad33c45242e73368a1b2b0442a17))
* **offchain:** preserve reference publications when funding bootstrap ([e8079e4](https://github.com/lambdasistemi/singular/commit/e8079e4fbe25c974a8078674e1a4b4f8dddb87e3))
* preserve exact spellings when attaching to a deployment ([df655ea](https://github.com/lambdasistemi/singular/commit/df655eacbf73390617b2fe4c59849b8621469da7))
* the retract window, the staking credential, and picking a big UTxO ([b53bff7](https://github.com/lambdasistemi/singular/commit/b53bff75a3bd5176add2663a4dfac47feb70c2f5)), closes [#102](https://github.com/lambdasistemi/singular/issues/102)
* **tools:** scan sh/py files and derive the rename gate allowlist ([#108](https://github.com/lambdasistemi/singular/issues/108)) ([fc2ad9e](https://github.com/lambdasistemi/singular/commit/fc2ad9e5987b171ca33a430f5bbe170ab6423fd5))
* **tools:** scan sh/py files and derive the rename gate allowlist ([#108](https://github.com/lambdasistemi/singular/issues/108)) ([a622ff7](https://github.com/lambdasistemi/singular/commit/a622ff72d45b320509d1e35cf7b09b062fb63e31))
* verify attached request identity without a local boot ([64b0053](https://github.com/lambdasistemi/singular/commit/64b005363f1f201a4593616d4b5420bbd96590ab))
* wait to the end of the retract window, not the start ([d07296e](https://github.com/lambdasistemi/singular/commit/d07296e52e09b8f9a640631e35e7a13fc4246cf5)), closes [#102](https://github.com/lambdasistemi/singular/issues/102)


### Documentation

* distinguish Over from an unclaimed spelling ([83da8c6](https://github.com/lambdasistemi/singular/commit/83da8c6e228df7c2c19bc1d4be2bc35f1ac841e8))
* what a deployment is, and what has to travel with its manifest ([6bf33d2](https://github.com/lambdasistemi/singular/commit/6bf33d2692617b280331884ab5eaaf8ffdebf557)), closes [#102](https://github.com/lambdasistemi/singular/issues/102)

## [0.5.0](https://github.com/lambdasistemi/singular/compare/v0.4.1...v0.5.0) (2026-09-14)


### Features

* external-node mode, joiner wallet and the onboarding runbook ([dd88246](https://github.com/lambdasistemi/singular/commit/dd88246a85fb0fe45e724ab1fce5d4a99f15affc))
* external-node mode, joiner wallet and the onboarding runbook ([dfd22de](https://github.com/lambdasistemi/singular/commit/dfd22de8e7003b13bc8c72a84dbe0ea20b12bac7)), closes [#78](https://github.com/lambdasistemi/singular/issues/78)


### Fixes

* keep the docs link in-tree and drop a dep external mode retired ([e0493ce](https://github.com/lambdasistemi/singular/commit/e0493ce96274f000b06c50496dde308cf34e5590))
* **release:** carry RELEASE-COMMIT so the on-chain archive replays without a git checkout ([#91](https://github.com/lambdasistemi/singular/issues/91)) ([7bad3dc](https://github.com/lambdasistemi/singular/commit/7bad3dcc545e4a3467d45630fb2053ee3af40c20))

## [0.4.1](https://github.com/lambdasistemi/singular/compare/v0.4.0...v0.4.1) (2026-09-14)


### Fixes

* check CS07 inventory with runner-available Bash ([b258622](https://github.com/lambdasistemi/singular/commit/b258622c63732d56cc77b06053ee7f7f245184a8))
* execute CS07 proof variants with devnet receipts ([e7021ce](https://github.com/lambdasistemi/singular/commit/e7021cefb16a9e4a444daa6cc53ec2f989b39e38))
* execute CS07 proof variants with devnet receipts ([6853aba](https://github.com/lambdasistemi/singular/commit/6853abaeca3e022ad96240bef58d839c8df391d3))
* replace the vendored MPF patch with upstream v2.1.0 ([8a83cd6](https://github.com/lambdasistemi/singular/commit/8a83cd6582852deda20623254eb56cd3efbacf57))
* replace the vendored MPF patch with upstream v2.1.0 ([a4e8e8f](https://github.com/lambdasistemi/singular/commit/a4e8e8ff8c61478d50ef51817f37c0a3601ae745))

## [0.4.0](https://github.com/lambdasistemi/singular/compare/v0.3.0...v0.4.0) (2026-09-13)


### Features

* bind completion burn policy to registry representative policy (intermediate, not final) ([0a691af](https://github.com/lambdasistemi/singular/commit/0a691af3c6370b319833b1166aa0fe133136d0b8))
* **conformance:** 40-row inventory with list and unit tests ([284bbc4](https://github.com/lambdasistemi/singular/commit/284bbc4920d20d17d1cb14ac33981e1a345229b7))
* **conformance:** CA01-CA05 canonical identity rows on the devnet ([619969e](https://github.com/lambdasistemi/singular/commit/619969ebc7f01154ac3fbb43e1ce0241f5a2e7e6))
* **conformance:** CG02-CG05 rows with node verdicts and receipts ([f59f542](https://github.com/lambdasistemi/singular/commit/f59f5427d9e8c5c45b71768787ac87fd154f074b))
* **conformance:** CS01 Haskell encodings vs compiled blueprint schema ([d36e992](https://github.com/lambdasistemi/singular/commit/d36e9927e770154080b3bc20444b74bf76734506))
* **conformance:** CS02 datum bytes survive chain round trip ([792ae19](https://github.com/lambdasistemi/singular/commit/792ae19a2b28dfaf89e49c602df3820f054ed2bd))
* **conformance:** CS06 parameter application derived in Haskell ([fe7a30c](https://github.com/lambdasistemi/singular/commit/fe7a30c2864f68ca5a176dd54433c52be3ef7237))
* **conformance:** CS07 unmarked, Fork instruments retained as finding tools ([d3e74da](https://github.com/lambdasistemi/singular/commit/d3e74da3bb84ac95402c563f1213dc4fcc7c821c))
* **conformance:** CS08 token state six fields survive None and Some ([59f7e0f](https://github.com/lambdasistemi/singular/commit/59f7e0f3b494e2495b9b638c56971795b1cccd62))
* **conformance:** executed is a receipt, not a field ([bc4af9c](https://github.com/lambdasistemi/singular/commit/bc4af9c45c2e89e686757e2baa087df48b68eae3))
* **conformance:** explicit CA/CG/CS partitions; CS07 vector-shaped Fork retry ([07aa224](https://github.com/lambdasistemi/singular/commit/07aa22478706b1d158298bff78f961b69f32cc90))
* **conformance:** local-check receipts for CS01 blueprint and CS06 params ([5fa914c](https://github.com/lambdasistemi/singular/commit/5fa914cd61440b17ec7683e6bd290e64cfc23e2d))
* **conformance:** present-key Fork grind and devnet probe instruments ([4a5cf1c](https://github.com/lambdasistemi/singular/commit/4a5cf1c36f7ce30871b1eb6e307945bd529c40ee))
* **conformance:** receipts bind tree state and rejected txids ([d1fd8cd](https://github.com/lambdasistemi/singular/commit/d1fd8cd160d4e7a94f7943dbd07663bb3cb8cf17))
* **conformance:** spike the synthesized-src build mechanism ([995f92a](https://github.com/lambdasistemi/singular/commit/995f92a1ca93e93e0fc4d787c654f3b0a7c49cbc))
* **conformance:** the pure canonical authenticator and its CA03 control ([22afeb7](https://github.com/lambdasistemi/singular/commit/22afeb79062d23b05a6ff71909f9b299d91a7851))
* connected Over journey with bound permissionless completion (intermediate, not final) ([27e5f9a](https://github.com/lambdasistemi/singular/commit/27e5f9a34f2a96356ce319885d5d0acc282dba62))
* **coverage:** obligation gate core — discovery, manifests, three debt axes, ratchet, completion (issue [#80](https://github.com/lambdasistemi/singular/issues/80)) ([3460896](https://github.com/lambdasistemi/singular/commit/34608963e485c5b08d1e733ae6eed0fc0fd29d39))
* **coverage:** package the gate — nix app, nix-built tests, CI job with distinct results (issue [#80](https://github.com/lambdasistemi/singular/issues/80)) ([dfb5215](https://github.com/lambdasistemi/singular/commit/dfb5215b1bdc1464bd4460b655b33d7dc11d871b))
* **coverage:** strict completion check and reporting CI job ([fb654d7](https://github.com/lambdasistemi/singular/commit/fb654d7ea9688491ce2fde1e7ee9583985a2f3ba))
* E17 delivery preflight repair — consumer-witness fixtures, connected Over story, truthful archive (intermediate, not final) ([bbd81f2](https://github.com/lambdasistemi/singular/commit/bbd81f2f86c07a9963e9a6aa35c1a8457d7ba38e))
* evidence-derived hook consumer with full ledger exhibit (intermediate, not final) ([a332b6a](https://github.com/lambdasistemi/singular/commit/a332b6a517b4c31242d815028582c65abac015f0))
* fold spelling-keyed names into Active with real representatives ([46d2e25](https://github.com/lambdasistemi/singular/commit/46d2e258b854c9366b28fe85f2035897729a861c))
* LX01/N2 eval-branch controls plus 83b359f re-integration (intermediate, not final) ([80ba8ef](https://github.com/lambdasistemi/singular/commit/80ba8eff8d06cdc89fc01ae9a55369ef42226cfc))
* recover control with the committed next key on a real ledger ([f01493e](https://github.com/lambdasistemi/singular/commit/f01493ef7f6580ab512490ce273a819104a584a6))
* recovery-then-retire journeys with public full-asset reader (intermediate, not final) ([954928c](https://github.com/lambdasistemi/singular/commit/954928c7d3f0da866f00c972fc64b641ebb9982a))
* release the connected claim, recovery and permanent retirement journey ([9c4dee1](https://github.com/lambdasistemi/singular/commit/9c4dee155f8463924fc4e58b6c087e56f9b022c2))
* retire by controller or registration quorum into completion-only custody ([646cc1b](https://github.com/lambdasistemi/singular/commit/646cc1b5e986a4a2543041b1c55fb3da695bf8b6))
* sixth State field pinning the consumer with a mandatory withdrawal hook ([ff0cbd3](https://github.com/lambdasistemi/singular/commit/ff0cbd3fd20e694c9f93480576e1f4277b93be75))


### Fixes

* adopt reviewed 196-obligation coverage baseline ([d21106f](https://github.com/lambdasistemi/singular/commit/d21106f0fab62e5db4665231e59f095fc9a8039e))
* bind representative policy to registry state (E-001) ([617e434](https://github.com/lambdasistemi/singular/commit/617e43440758d779a94a2aea35aab6540ec796ec))
* carry git in on-chain release assembler closure ([ddfc4e9](https://github.com/lambdasistemi/singular/commit/ddfc4e961d530ee4e62361aabbcc730a9b9809ed))
* **ci:** enforce partial inventory using Bash builtins ([2321e1b](https://github.com/lambdasistemi/singular/commit/2321e1bbe8e45ca5b07404c8452101cb3a120e68))
* **conformance:** keep every failing script hash in refusal attribution ([3a74b5d](https://github.com/lambdasistemi/singular/commit/3a74b5d4b1886669b58119c3fe54c2466f4c4dd0))
* **conformance:** observe tree identity before creating receipts output ([b2201c3](https://github.com/lambdasistemi/singular/commit/b2201c3b2e3cd27b7ad261ee2f6a0fcbeedc5a8b))
* **conformance:** parseable workflow, speech companion, lint gate ([ca3af4a](https://github.com/lambdasistemi/singular/commit/ca3af4a2b06c68814da83fa14467bba6d0960fce))
* **coverage:** failure-safe session teardown for devnet stories ([e48de2c](https://github.com/lambdasistemi/singular/commit/e48de2c889a8670b88704c9b6cb15f4dba4d41ee))
* make folding permissionless and retraction insert-only ([bf9f42d](https://github.com/lambdasistemi/singular/commit/bf9f42db5ca420171f9f13cd892f005292a1aa7e))
* ownerless prose consistency for the operator ruling ([55dea40](https://github.com/lambdasistemi/singular/commit/55dea40d6140ed8f42372e4b787f9e3e96e8cffc))
* ownerless registry per operator ruling NOTE-028/A-003 ([f3a68b1](https://github.com/lambdasistemi/singular/commit/f3a68b1bcd63119f8db79548a7d15926bf408856))
* **rebase:** merge duplicate Scripts.Data import after CA rebase ([a5104c2](https://github.com/lambdasistemi/singular/commit/a5104c21e64ddca5ccc5ce4651dfd791dacb5801))
* rename tampered representative row to misnamed ([0891eb1](https://github.com/lambdasistemi/singular/commit/0891eb1c4d6c5caff4ccd495eac72a0eca4a1ad5))
* repair-batch E-001 cause, producer identity, release source binding ([fe89e68](https://github.com/lambdasistemi/singular/commit/fe89e686d6be5343a9818f470b99942a5f5589f2))
* two more ownerless prose sites per NOTE-013 ([d1fc24a](https://github.com/lambdasistemi/singular/commit/d1fc24a67b732d10320cf4decc59013d5647f9b7))


### Documentation

* **conformance:** bind measurements to the ship run ([6252912](https://github.com/lambdasistemi/singular/commit/62529127294893fa6c5020105a3f8902e190e676))
* **conformance:** bind measurements to the ship run ([b08e458](https://github.com/lambdasistemi/singular/commit/b08e458717db02a561067f8ab909957d82bc53dd))
* **conformance:** CS boundary rows, unmarked CS07, workflow family step ([b6f7a51](https://github.com/lambdasistemi/singular/commit/b6f7a518cce96925aaefeeee19c81f63c335c817))
* **conformance:** numbers from the clean-tree run ([8cd9ef0](https://github.com/lambdasistemi/singular/commit/8cd9ef02d1934abf77b6f25a884145e93afc02c2))
* **conformance:** the canonical identity rows in the consumer page ([b3f4b5a](https://github.com/lambdasistemi/singular/commit/b3f4b5a8f243a72627d74bc6a0fe112ea614bb28))
* correct fold value-routing citation and owner-pinning framing ([#89](https://github.com/lambdasistemi/singular/issues/89)) ([c800023](https://github.com/lambdasistemi/singular/commit/c8000231afc32510fe9851c6727f3e0fe8961c96))
* **coverage:** bind cleanup evidence to transcripts, fix marker uniqueness ([8fcc532](https://github.com/lambdasistemi/singular/commit/8fcc532b180e367b5fcbf5616ecea76b9405dc36))
* **coverage:** correct fold_iff correspondence page ([7db148b](https://github.com/lambdasistemi/singular/commit/7db148b2c2a43a03faab056442fe0d185985a4ed))
* **coverage:** inhabit the fold_iff Insert exhibit, separate held zero-side ([30b6d03](https://github.com/lambdasistemi/singular/commit/30b6d0378e10b0b36d771d14a7505fbd6c420c91))
* **coverage:** name the candidate commit in evidence transcripts ([0aba3ae](https://github.com/lambdasistemi/singular/commit/0aba3ae7c77e4ff309703a0b12e5e3976d0369c6))
* **coverage:** qualify non-vacuity wording both directions ([062017c](https://github.com/lambdasistemi/singular/commit/062017cfecd3cf54aff9e0141ae65282efa8de1d))
* **coverage:** render fold_iff — the correspondence format under load (issue [#80](https://github.com/lambdasistemi/singular/issues/80); NOTE-004/005 repair) ([569bfa7](https://github.com/lambdasistemi/singular/commit/569bfa700aaa63f9f4c09883a3fdfff151cf0962))
* **coverage:** show the S13d arithmetic and the empty-fold absence check ([64567dd](https://github.com/lambdasistemi/singular/commit/64567dd54fed8af19e85ca9e99e797a054940077))
* **coverage:** tasty-bdd bounded evaluation, human-correspondence view, gate README (issue [#80](https://github.com/lambdasistemi/singular/issues/80)) ([c1865d9](https://github.com/lambdasistemi/singular/commit/c1865d9900bf94986d53f12ea233fe182472106d))
* establish Lean authority in the repository constitution ([91f0053](https://github.com/lambdasistemi/singular/commit/91f005321d3678c423e1656121fb18cca06ae466))
* make Lean authority binding across implementation and releases ([ef25464](https://github.com/lambdasistemi/singular/commit/ef25464775d871e230f095740100738738647cac))


### Automation

* bind held observations and refund controls to complete evidence ([fec5ab2](https://github.com/lambdasistemi/singular/commit/fec5ab23dc25b16a6bcb1d0c19f80c03247bae2a))
* **conformance:** run the canonical-identity rows ([21246cb](https://github.com/lambdasistemi/singular/commit/21246cb51ea2305172ff0cd042b8232665effbca))
* keep conformance receipts outside the source checkout ([cd40fe5](https://github.com/lambdasistemi/singular/commit/cd40fe59cacf782287a89f3b0b2e5afe1e2571bf))
* lint jq programs with their intended variable scope ([3b749ce](https://github.com/lambdasistemi/singular/commit/3b749cec5272fb4709019d1a4333aefcb4786f8a))
* pass MPFS blueprint to recovery/retirement jobs plus truthful scope comments (NOTE-045/047) ([e3349f0](https://github.com/lambdasistemi/singular/commit/e3349f008cba3ef65dc1c36614e1397110b7dfbd))

## [0.3.0](https://github.com/lambdasistemi/singular/compare/v0.2.0...v0.3.0) (2026-09-11)


### Features

* author Singular's naming validators, and fix an unenforced LC04 ([330063c](https://github.com/lambdasistemi/singular/commit/330063c135f9c73438e2a4be64b1cab3352773ae))
* execute the contract's LI01 canonical initialization on a real ledger ([b23199a](https://github.com/lambdasistemi/singular/commit/b23199a651a425ed00fa46d0fdbfe8b523c8eda7))
* execute the maintenance and cancellation rows on a real ledger ([9fc92a7](https://github.com/lambdasistemi/singular/commit/9fc92a7d1e1734725e82f874a240b67b9858f1ac))
* exercise the seven wrong canonical initializations on a real ledger ([0a6f6a1](https://github.com/lambdasistemi/singular/commit/0a6f6a12fa3d0afefab1bc66236810cad2e02a79))
* implement the naming datum codec against the contract's own bytes ([5302fe6](https://github.com/lambdasistemi/singular/commit/5302fe61226f0b11372bf9c329bddc8e76c7f7bc))
* make drift between the vendored vectors and the live corpus visible ([9e7a7d9](https://github.com/lambdasistemi/singular/commit/9e7a7d9ede0db028d79cdd338baf4c48ba93a7cc))
* package the epic's on-chain work as a retrievable release ([43af209](https://github.com/lambdasistemi/singular/commit/43af209dc812f7314f335c83acf02eed153ebc0e))
* tie the applied script identities to the pinned unapplied ones ([dd9f552](https://github.com/lambdasistemi/singular/commit/dd9f55208a9343e5a8518964eac8241878006835))


### Fixes

* keep the parameter counts when regenerating the identity manifest ([925222b](https://github.com/lambdasistemi/singular/commit/925222b6f3c91f87a03f43698528a0aad74a1e9d))
* restore the newline that merged two workflow steps into one ([572182f](https://github.com/lambdasistemi/singular/commit/572182f43ec059576f7974c348f866ac9485cfcd))

## [0.2.0](https://github.com/lambdasistemi/singular/compare/v0.1.0...v0.2.0) (2026-09-10)


### Features

* add admitted Lean model and playable Singular simulation ([b23f1f7](https://github.com/lambdasistemi/singular/commit/b23f1f7c4fb9628971208d5ec80e6b647c5bacbf))
* add playable Lean-derived Singular simulation ([d5e6795](https://github.com/lambdasistemi/singular/commit/d5e679557f9301998fc640cc525e2c8b4fee364a))
* give epic 16 a runnable artifact that narrates the journey ([244c189](https://github.com/lambdasistemi/singular/commit/244c189958db44e55d41d730dca4e564e8309dc8))
* make the imported MPFS trees build and pass their devnet E2E ([1737f84](https://github.com/lambdasistemi/singular/commit/1737f8496d90da1d2467a8365c543db0e72bcb35))
* make the journey verify absence, liveness and a false claim ([1177f47](https://github.com/lambdasistemi/singular/commit/1177f470bc2d0fcb14381bcb5c25ffd6c6d64929))
* model Singular with admitted statements ([f1d59a7](https://github.com/lambdasistemi/singular/commit/f1d59a7ad1fbd7aeb74e1e528e7d49e391bf7c20))
* naming lifecycle and cancellation (maintenance, recovery, retirement, consumer binding) ([#35](https://github.com/lambdasistemi/singular/issues/35)) ([eb90b66](https://github.com/lambdasistemi/singular/commit/eb90b66af5f2f46552e4b4628343d7150352492d))
* naming lifecycle transitions (maintenance, recovery, retirement) + consumer scenarios ([#32](https://github.com/lambdasistemi/singular/issues/32)) ([c977ad6](https://github.com/lambdasistemi/singular/commit/c977ad67f26605af71faac389b7fa9d0a55c617e))
* observe the validators refusing forged and tampered transactions ([7abe1c3](https://github.com/lambdasistemi/singular/commit/7abe1c3527c5ddf5446686e40b60c9833caa454d))
* pin and enforce compiled script identity ([24bb301](https://github.com/lambdasistemi/singular/commit/24bb30148327f3d77fa28081938fa93feb0759d4))
* pin the proved model and its manifest in the simulator ([5efcde2](https://github.com/lambdasistemi/singular/commit/5efcde2e034b6ec3e906f20b9eb5da3cf4b18b55))
* prove the 41 model statements and gate compiled axioms ([176693e](https://github.com/lambdasistemi/singular/commit/176693ed5573e33cb99ec6a8acb8b9cce7e7a3d6))
* split the imported MPFS trees into two self-contained flakes ([f3e77cc](https://github.com/lambdasistemi/singular/commit/f3e77cccefa12d699c72cb91bf2118abc0307cb8))


### Fixes

* bind the checker to its source tree instead of its site argument ([76d4476](https://github.com/lambdasistemi/singular/commit/76d447653d2d57d62ee95b2d756ff8c5b2fb0d9d))
* cover simulator documentation in read-aloud metadata ([da3a37a](https://github.com/lambdasistemi/singular/commit/da3a37aac3e78eafcbb1d00f0abfe0d801f81d3f))
* initialize isolated CI caches in job steps ([0de7939](https://github.com/lambdasistemi/singular/commit/0de79399fd37cfe64ddffdbb7c542de064be2003))
* preserve presentation and support restricted CI browsers ([9d43347](https://github.com/lambdasistemi/singular/commit/9d43347a1078ab56c81a98945223fd04aa3c39cb))
* report each served surface's own identity evidence ([31fcde7](https://github.com/lambdasistemi/singular/commit/31fcde75242eeeaa6f813c663e0b001b2b53a6a7))
* run the devnet gate from the Nix-built binary instead of cabal ([20f88f6](https://github.com/lambdasistemi/singular/commit/20f88f6c178dc0aeb287c9be8813b9fbb56495fb))


### Documentation

* anchor application authorization to configured policy ([d27c2b6](https://github.com/lambdasistemi/singular/commit/d27c2b6b164d66c014481951259472beca7c2b2a))
* bind candidate narration to the final page sources ([5917d47](https://github.com/lambdasistemi/singular/commit/5917d470a01ecf828b6d02bc8c7024b53f8b1462))
* bind every speech companion to its page hash and gate staleness ([7878675](https://github.com/lambdasistemi/singular/commit/78786757146faf96d0fe5bb2c2155c2dc7abcd9c))
* bind every speech companion to its page hash and gate staleness ([fec14fb](https://github.com/lambdasistemi/singular/commit/fec14fb8848bdb3f35fa09fbd3c15678b5ed84cd))
* bind Insert and Withdraw to application action tokens ([1c30484](https://github.com/lambdasistemi/singular/commit/1c30484c1840994ee83a06b53c92a1daabf340a8))
* bind published model evidence to the shipped candidate artifacts ([f03eac8](https://github.com/lambdasistemi/singular/commit/f03eac8ef27a5fe812f708f52d4f6795a3eb8fbe))
* compare MPFS and separate the reuse layers ([8f83ffe](https://github.com/lambdasistemi/singular/commit/8f83ffeca383e9a1c668c7d2fbecda97b0fafc36))
* compare MPFS and separate the reuse layers ([ffdb6e7](https://github.com/lambdasistemi/singular/commit/ffdb6e7c2ce015ef2ba69642f403062a13114a57))
* complete action-token custody and cancellation description ([ac52fa5](https://github.com/lambdasistemi/singular/commit/ac52fa545bbf4aaf3cb9fbd1d7c8445d8d709663))
* define certified registry and naming demonstration ([fac38e6](https://github.com/lambdasistemi/singular/commit/fac38e643aa5d93f5bb6bb88acd9b9dd5b78e66f))
* deliver MkDocs site with pinned Nix checks and previews ([06553e4](https://github.com/lambdasistemi/singular/commit/06553e484de98bb09ccbb33a6fade2356657b3ee))
* derive draft registry protocol requirements ([c0eb958](https://github.com/lambdasistemi/singular/commit/c0eb9584ce892aad1cd10b4f7040da820ac8b4c8))
* derive witness and naming conformance obligations ([bb54e02](https://github.com/lambdasistemi/singular/commit/bb54e02fff2e8a54a4055629872d014362551f9c))
* distinguish action approval from Singular admission ([311b6b4](https://github.com/lambdasistemi/singular/commit/311b6b41d1b80e070678af5ba0e3813682fcaffa))
* distinguish scoped approval reuse from replay ([c1f3410](https://github.com/lambdasistemi/singular/commit/c1f3410be73873eacd2709882b493b0cbea0c703))
* explain certified requests and NFT custody ([da73019](https://github.com/lambdasistemi/singular/commit/da7301973bb4c88930163b562ec3346fe5022b95))
* explain net minting and token movement boundaries ([65fdf74](https://github.com/lambdasistemi/singular/commit/65fdf745a1b6cdd9845e1fcc7fe4ca8d2e25e842))
* ground protocol boundaries and add naming walkthrough ([606239f](https://github.com/lambdasistemi/singular/commit/606239f6ce854098242247e5ea93f64508f81062))
* leave request issuer composition explicit in draft spec ([00f8e4c](https://github.com/lambdasistemi/singular/commit/00f8e4cfa52c2b6c6e7751710261d6d3900ff863))
* point simulator CTAs at the playable GitHub Pages URL ([3469efa](https://github.com/lambdasistemi/singular/commit/3469efa2b8c7fb1ccc721d9ab0d1138e87b8751f))
* present the design through stories and diagrams and gate it ([40aa6fc](https://github.com/lambdasistemi/singular/commit/40aa6fc0c1a79c324f7562f585d57614d8014261))
* present the design through stories and diagrams and gate it ([f37a538](https://github.com/lambdasistemi/singular/commit/f37a538fff104f6e32dae1ec6022ffc76c5b5bae))
* qualify policy invocation and date source comparison ([2d867f2](https://github.com/lambdasistemi/singular/commit/2d867f27c2ab8d776db6ec77d81c4adb0a4d1e84))
* quote flowchart edge labels and reflow the tall diagrams ([82e6d9b](https://github.com/lambdasistemi/singular/commit/82e6d9be3afa59eb08c4235f900d58b379c43654))
* read prior art on the reuse axis and separate the retirement modes ([d69a2fa](https://github.com/lambdasistemi/singular/commit/d69a2fae011e5f24951d595c34d88f9c34931b0f))
* remove a statement separator from a sequence message ([f60f2a4](https://github.com/lambdasistemi/singular/commit/f60f2a40ac9b250e7fcbd19523af2342138a9709))
* repair README/docs links with candidate-bound evidence and served-route verification ([4169662](https://github.com/lambdasistemi/singular/commit/41696628105ea12610251ce8f2ac759e5e985889))
* report the proved statement surface ([a1d5fc2](https://github.com/lambdasistemi/singular/commit/a1d5fc2ff282a940d5fcaa98e509ab4ba09a48bb))
* serve the pinned Mermaid from the site and forbid external resources ([d806d93](https://github.com/lambdasistemi/singular/commit/d806d932b821b1ce0925c612da484ac439ad90cb))
* specify application action assets for Insert and Withdraw ([3acbe36](https://github.com/lambdasistemi/singular/commit/3acbe36012a85d5e342e60dd9e2a49a9ffab6fcb))
* specify live README and documentation link repair ([f00b580](https://github.com/lambdasistemi/singular/commit/f00b5800024dcc5dfe6d2a64404fed3157ee81d0))
* verify published bytes through a dedicated Nix app ([240499e](https://github.com/lambdasistemi/singular/commit/240499e462174bb3fa63d10240743f0b368d155f))


### Automation

* execute browser checks and realize the complete build gate ([2702a1f](https://github.com/lambdasistemi/singular/commit/2702a1fc881976e51f0950e14c46bf7f3cb74fa3))
* gate the documentation development shell build ([9d410d3](https://github.com/lambdasistemi/singular/commit/9d410d33ab6f30d4935175258c83991e490bf8a4))
* prepare comment-free documentation releases and tagged artifacts ([b0bc6bf](https://github.com/lambdasistemi/singular/commit/b0bc6bff2e20d56eb443fe0c358b7509403d01b9))

## 0.1.0 (2026-09-09)


### Features

* add admitted Lean model and playable Singular simulation ([b23f1f7](https://github.com/lambdasistemi/singular/commit/b23f1f7c4fb9628971208d5ec80e6b647c5bacbf))
* add playable Lean-derived Singular simulation ([d5e6795](https://github.com/lambdasistemi/singular/commit/d5e679557f9301998fc640cc525e2c8b4fee364a))
* model Singular with admitted statements ([f1d59a7](https://github.com/lambdasistemi/singular/commit/f1d59a7ad1fbd7aeb74e1e528e7d49e391bf7c20))
* pin the proved model and its manifest in the simulator ([5efcde2](https://github.com/lambdasistemi/singular/commit/5efcde2e034b6ec3e906f20b9eb5da3cf4b18b55))
* prove the 41 model statements and gate compiled axioms ([176693e](https://github.com/lambdasistemi/singular/commit/176693ed5573e33cb99ec6a8acb8b9cce7e7a3d6))


### Fixes

* cover simulator documentation in read-aloud metadata ([da3a37a](https://github.com/lambdasistemi/singular/commit/da3a37aac3e78eafcbb1d00f0abfe0d801f81d3f))
* initialize isolated CI caches in job steps ([0de7939](https://github.com/lambdasistemi/singular/commit/0de79399fd37cfe64ddffdbb7c542de064be2003))
* preserve presentation and support restricted CI browsers ([9d43347](https://github.com/lambdasistemi/singular/commit/9d43347a1078ab56c81a98945223fd04aa3c39cb))


### Documentation

* anchor application authorization to configured policy ([d27c2b6](https://github.com/lambdasistemi/singular/commit/d27c2b6b164d66c014481951259472beca7c2b2a))
* bind candidate narration to the final page sources ([5917d47](https://github.com/lambdasistemi/singular/commit/5917d470a01ecf828b6d02bc8c7024b53f8b1462))
* bind every speech companion to its page hash and gate staleness ([7878675](https://github.com/lambdasistemi/singular/commit/78786757146faf96d0fe5bb2c2155c2dc7abcd9c))
* bind every speech companion to its page hash and gate staleness ([fec14fb](https://github.com/lambdasistemi/singular/commit/fec14fb8848bdb3f35fa09fbd3c15678b5ed84cd))
* bind Insert and Withdraw to application action tokens ([1c30484](https://github.com/lambdasistemi/singular/commit/1c30484c1840994ee83a06b53c92a1daabf340a8))
* compare MPFS and separate the reuse layers ([8f83ffe](https://github.com/lambdasistemi/singular/commit/8f83ffeca383e9a1c668c7d2fbecda97b0fafc36))
* compare MPFS and separate the reuse layers ([ffdb6e7](https://github.com/lambdasistemi/singular/commit/ffdb6e7c2ce015ef2ba69642f403062a13114a57))
* complete action-token custody and cancellation description ([ac52fa5](https://github.com/lambdasistemi/singular/commit/ac52fa545bbf4aaf3cb9fbd1d7c8445d8d709663))
* define certified registry and naming demonstration ([fac38e6](https://github.com/lambdasistemi/singular/commit/fac38e643aa5d93f5bb6bb88acd9b9dd5b78e66f))
* deliver MkDocs site with pinned Nix checks and previews ([06553e4](https://github.com/lambdasistemi/singular/commit/06553e484de98bb09ccbb33a6fade2356657b3ee))
* derive draft registry protocol requirements ([c0eb958](https://github.com/lambdasistemi/singular/commit/c0eb9584ce892aad1cd10b4f7040da820ac8b4c8))
* derive witness and naming conformance obligations ([bb54e02](https://github.com/lambdasistemi/singular/commit/bb54e02fff2e8a54a4055629872d014362551f9c))
* distinguish action approval from Singular admission ([311b6b4](https://github.com/lambdasistemi/singular/commit/311b6b41d1b80e070678af5ba0e3813682fcaffa))
* distinguish scoped approval reuse from replay ([c1f3410](https://github.com/lambdasistemi/singular/commit/c1f3410be73873eacd2709882b493b0cbea0c703))
* explain certified requests and NFT custody ([da73019](https://github.com/lambdasistemi/singular/commit/da7301973bb4c88930163b562ec3346fe5022b95))
* explain net minting and token movement boundaries ([65fdf74](https://github.com/lambdasistemi/singular/commit/65fdf745a1b6cdd9845e1fcc7fe4ca8d2e25e842))
* ground protocol boundaries and add naming walkthrough ([606239f](https://github.com/lambdasistemi/singular/commit/606239f6ce854098242247e5ea93f64508f81062))
* leave request issuer composition explicit in draft spec ([00f8e4c](https://github.com/lambdasistemi/singular/commit/00f8e4cfa52c2b6c6e7751710261d6d3900ff863))
* present the design through stories and diagrams and gate it ([40aa6fc](https://github.com/lambdasistemi/singular/commit/40aa6fc0c1a79c324f7562f585d57614d8014261))
* present the design through stories and diagrams and gate it ([f37a538](https://github.com/lambdasistemi/singular/commit/f37a538fff104f6e32dae1ec6022ffc76c5b5bae))
* qualify policy invocation and date source comparison ([2d867f2](https://github.com/lambdasistemi/singular/commit/2d867f27c2ab8d776db6ec77d81c4adb0a4d1e84))
* quote flowchart edge labels and reflow the tall diagrams ([82e6d9b](https://github.com/lambdasistemi/singular/commit/82e6d9be3afa59eb08c4235f900d58b379c43654))
* read prior art on the reuse axis and separate the retirement modes ([d69a2fa](https://github.com/lambdasistemi/singular/commit/d69a2fae011e5f24951d595c34d88f9c34931b0f))
* remove a statement separator from a sequence message ([f60f2a4](https://github.com/lambdasistemi/singular/commit/f60f2a40ac9b250e7fcbd19523af2342138a9709))
* report the proved statement surface ([a1d5fc2](https://github.com/lambdasistemi/singular/commit/a1d5fc2ff282a940d5fcaa98e509ab4ba09a48bb))
* serve the pinned Mermaid from the site and forbid external resources ([d806d93](https://github.com/lambdasistemi/singular/commit/d806d932b821b1ce0925c612da484ac439ad90cb))
* specify application action assets for Insert and Withdraw ([3acbe36](https://github.com/lambdasistemi/singular/commit/3acbe36012a85d5e342e60dd9e2a49a9ffab6fcb))
* verify published bytes through a dedicated Nix app ([240499e](https://github.com/lambdasistemi/singular/commit/240499e462174bb3fa63d10240743f0b368d155f))


### Automation

* execute browser checks and realize the complete build gate ([2702a1f](https://github.com/lambdasistemi/singular/commit/2702a1fc881976e51f0950e14c46bf7f3cb74fa3))
* gate the documentation development shell build ([9d410d3](https://github.com/lambdasistemi/singular/commit/9d410d33ab6f30d4935175258c83991e490bf8a4))
* prepare comment-free documentation releases and tagged artifacts ([b0bc6bf](https://github.com/lambdasistemi/singular/commit/b0bc6bff2e20d56eb443fe0c358b7509403d01b9))
