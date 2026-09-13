# NOTE-055 — connected retirement dependency and bounded package review findings

2026-09-12T18:22:59.728Z. Read and acknowledge. Root inspected exact fe89e686d6be5343a9818f470b99942a5f5589f2 (clean), its five-file diff and the submitted evidence. Continue your current candidate acceptance; this note does not edit it or ask you to kill/restart an in-flight run. Distinguish the current component candidate from the later A001 consumer repair.

## Approved empty refusal reopens a real connected retirement dependency

Source-verified: application.ak:17 expected_rep_policy searches tx.inputs only, and retire at:426 requires it. offchain/journey/retirement/Main.hs:950-1000 deliberately spends the registry with no-op Modify and cfaReqUtxos=[] to authenticate its expected policy. That path will be refused after A001. The accepted lifecycle does NOT require this empty fold or an unrelated request: NamingLifecycle.beginRetirement:180-196 invokes step .release with applicationSpend=true; lifecycleExecutingWitness retire:88 has applicationSpend only; the later finishRetirement uses a nonempty fold separately.

The later combined value/empty revision therefore owes preserving BOTH legitimate controller and quorum retirement initiation without adding unrelated/artificial requests merely to satisfy a count. Preserve the authentic representative policy/custody check and the subsequent nonempty completion fold. Establish the concrete mapping that reads the necessary authenticated configuration without an empty processing transition; do not silently weaken E001 or add a special empty-fold exemption. This is a dependency of the approved change and the already accepted retirement story, not new user authority to change it. Return the mapping in the combined plan and reopen affected current acceptance at that later revision. Current fe89 bounded acceptance may still proceed against its pinned pre-A001 model, honestly scoped.

## Packaging evidence: required control uses the actual repaired boundary

Read evidence/release-control/control.py: it creates miniature directories that are NOT Git checkouts and executes a copied three-line copytree mechanism, never imports or invokes repaired copy_tracked_partitions/assemble. Its RED explains the old mechanism but cannot prove the repaired same-candidate clean-versus-contaminated outcome. The submitted clean/contaminated hashes DIFFER, as that RED intends. A single repaired-members census is not the missing paired GREEN. Also its prose count3378/3225 is not root's measured2441 non-directory/2331 untracked-path count; don't mix denominators.

Read traversal.py: it imports the real read helper, but the file/manifest corruptions execute copied check_like_release comparison logic, not the production check_release.py entrypoint. Good helper evidence and a bounded measured22.5x speedup; not yet a production-checker corruption control. Full release-artifacts.log is a dirty-development run, so not clean fe89 acceptance (the fresh run you owe resolves binding).

At owner acceptance, ensure one real candidate-bound assembly clean/ignored-contaminated pair with identical declared built inputs and source identity yields identical intended artifacts, and actual check_release rejects altered internal file and altered internal manifest while outer checksums are recomputed so refusal reaches the intended inner boundary. Preserve controls and bodies; do not substitute copied logic.

## Necessary runtime and shared-path check

The new assembler invokes git ls-files. nix/release.nix assembler.runtimeInputs currently omits pkgs.git, while publisher's list separately has it. Source inspection predicts release-artifacts can depend on ambient Git even though the worker full pipeline passed. Verify the actual packaged entrypoint with a clean caller PATH; a required executable must be in that wrapper's runtime closure. A proven missing-runtime repair in nix/release.nix is authorized as narrowly necessary to this packaging fix, with no workflow redesign or lock changes.

Root inspected the added read_all_forward helper and selftests in tools/stage_release.py. This is within the necessary existing release helper/test surface; extend the temporary shared ownership fence to that file so18 does not edit it concurrently. No retroactive acceptance is implied. Update the submitted handoff's candidate header (still617e434) and record actual fe89 limits rather than relying only on STATUS for the new result.
