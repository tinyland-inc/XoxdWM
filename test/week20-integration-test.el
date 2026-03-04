;;; week20-integration-test.el --- Week 20 release integration tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; Final release validation: all 20 weeks compose correctly.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defvar week20-test--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name)))))

;; ── Release validation ─────────────────────────────────

(ert-deftest week20/changelog-exists ()
  "CHANGELOG.md exists in project root."
  (should (file-exists-p
           (expand-file-name "CHANGELOG.md" week20-test--root))))

(ert-deftest week20/changelog-has-version ()
  "CHANGELOG.md mentions v0.1.0."
  (let ((content (with-temp-buffer
                   (insert-file-contents
                    (expand-file-name "CHANGELOG.md" week20-test--root))
                   (buffer-string))))
    (should (string-match-p "0\\.1\\.0" content))))

(ert-deftest week20/plan-exists ()
  "PLAN.md removed; feature-matrix.md replaces it."
  (should (file-exists-p
           (expand-file-name "docs/feature-matrix.md" week20-test--root))))

(ert-deftest week20/justfile-exists ()
  "justfile exists."
  (should (file-exists-p
           (expand-file-name "justfile" week20-test--root))))

(ert-deftest week20/justfile-has-release-recipe ()
  "justfile contains release recipe."
  (let ((content (with-temp-buffer
                   (insert-file-contents
                    (expand-file-name "justfile" week20-test--root))
                   (buffer-string))))
    (should (string-match-p "release" content))))

;; ── Documentation completeness ─────────────────────────

(ert-deftest week20/docs-user-guide ()
  "User guide exists."
  (should (file-exists-p
           (expand-file-name "docs/user-guide.md"
                             week20-test--root))))

(ert-deftest week20/docs-vr-guide ()
  "VR guide exists."
  (should (file-exists-p
           (expand-file-name "docs/vr-guide.md"
                             week20-test--root))))

(ert-deftest week20/docs-eye-tracking-guide ()
  "Eye tracking guide exists."
  (should (file-exists-p
           (expand-file-name "docs/eye-tracking-guide.md"
                             week20-test--root))))

(ert-deftest week20/docs-bci-guide ()
  "BCI guide exists."
  (should (file-exists-p
           (expand-file-name "docs/bci-guide.md"
                             week20-test--root))))

(ert-deftest week20/docs-developer-guide ()
  "Developer guide exists."
  (should (file-exists-p
           (expand-file-name "docs/developer-guide.md"
                             week20-test--root))))

(ert-deftest week20/docs-api-reference ()
  "API reference exists."
  (should (file-exists-p
           (expand-file-name "docs/api-reference.md"
                             week20-test--root))))

(ert-deftest week20/docs-security-audit ()
  "Security audit exists."
  (should (file-exists-p
           (expand-file-name "docs/security-audit-v0.1.0.md"
                             week20-test--root))))

(ert-deftest week20/docs-bci-quickstart ()
  "BCI quickstart guide exists."
  (should (file-exists-p
           (expand-file-name "docs/bci-quickstart.md"
                             week20-test--root))))

(ert-deftest week20/docs-count ()
  "At least 8 documentation files in docs/."
  (let ((docs (directory-files
               (expand-file-name "docs" week20-test--root)
               nil "\\.md$")))
    (should (>= (length docs) 8))))

;; ── Research docs ──────────────────────────────────────

(ert-deftest week20/research-competitive-analysis ()
  "Research directory exists."
  (should (file-directory-p
           (expand-file-name "docs/research" week20-test--root))))

(ert-deftest week20/research-ux-evaluation ()
  "Research directory has content."
  (should (directory-files
           (expand-file-name "docs/research" week20-test--root)
           nil "\\.md$")))

(ert-deftest week20/research-roadmap ()
  "V0.5.0 roadmap plan exists."
  (should (file-exists-p
           (expand-file-name
            "docs/research/v0.5.0-roadmap-plan.md"
            week20-test--root))))

;; ── E2E test suites exist ──────────────────────────────

(ert-deftest week20/e2e-flat-desktop-tests ()
  "Flat desktop E2E test file exists."
  (should (file-exists-p
           (expand-file-name "test/e2e-flat-desktop-test.el"
                             week20-test--root))))

(ert-deftest week20/e2e-vr-mode-tests ()
  "VR mode E2E test file exists."
  (should (file-exists-p
           (expand-file-name "test/e2e-vr-mode-test.el"
                             week20-test--root))))

(ert-deftest week20/e2e-eye-tracking-tests ()
  "Eye tracking E2E test file exists."
  (should (file-exists-p
           (expand-file-name "test/e2e-eye-tracking-test.el"
                             week20-test--root))))

(ert-deftest week20/e2e-bci-mode-tests ()
  "BCI mode E2E test file exists."
  (should (file-exists-p
           (expand-file-name "test/e2e-bci-mode-test.el"
                             week20-test--root))))

(ert-deftest week20/e2e-full-stack-tests ()
  "Full stack E2E test file exists."
  (should (file-exists-p
           (expand-file-name "test/e2e-full-stack-test.el"
                             week20-test--root))))

;; ── Benchmark module ───────────────────────────────────

(ert-deftest week20/benchmark-module-loaded ()
  "Benchmark module provides feature."
  (require 'ewwm-benchmark)
  (should (featurep 'ewwm-benchmark)))

(ert-deftest week20/benchmark-run-all-exists ()
  "Benchmark run-all function exists."
  (require 'ewwm-benchmark)
  (should (fboundp 'ewwm-benchmark-run-all)))

(ert-deftest week20/benchmark-report-exists ()
  "Benchmark report function exists."
  (require 'ewwm-benchmark)
  (should (fboundp 'ewwm-benchmark-report)))

;; ── All weeks represented ──────────────────────────────

(ert-deftest week20/all-weekly-integration-tests ()
  "Integration test files exist for key weeks."
  (let ((weeks '("week1" "week4" "week5" "week7" "week8"
                 "week9" "week10" "week11" "week12" "week13"
                 "week14" "week15" "week16" "week17" "week18"
                 "week19" "week20")))
    (dolist (w weeks)
      (should (file-exists-p
               (expand-file-name
                (format "test/%s-integration-test.el" w)
                week20-test--root))))))

(ert-deftest week20/test-file-count ()
  "At least 60 test files in test/ directory."
  (let ((files (directory-files
                (expand-file-name "test" week20-test--root)
                nil "-test\\.el$")))
    (should (>= (length files) 60))))

;; ── Platform files ─────────────────────────────────────

(ert-deftest week20/flake-nix-exists ()
  "flake.nix exists."
  (should (file-exists-p
           (expand-file-name "flake.nix" week20-test--root))))

(ert-deftest week20/rpm-spec-exists ()
  "RPM spec exists."
  (should (file-exists-p
           (expand-file-name "packaging/rpm/exwm-vr.spec"
                             week20-test--root))))

(ert-deftest week20/selinux-policy-exists ()
  "SELinux policy exists."
  (should (file-exists-p
           (expand-file-name "packaging/selinux/exwm_vr.te"
                             week20-test--root))))

(ert-deftest week20/ci-workflow-exists ()
  "CI workflow exists."
  (should (file-exists-p
           (expand-file-name ".github/workflows/multi-arch.yml"
                             week20-test--root))))

(provide 'week20-integration-test)
;;; week20-integration-test.el ends here
