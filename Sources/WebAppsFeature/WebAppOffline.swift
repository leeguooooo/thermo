import Foundation

/// Per-app adjustments for running without Puter: cloud-only controls are hidden, saving goes to a
/// file on this Mac, and wording about a Puter account is replaced. Matched by the apps' own command
/// ids and labels, so an upstream update that renames one only leaves that control visible.
extension WebApp {
    var offlineScript: String {
        let config: String
        switch self {
        case .pdf:
            config = #"""
            {
              css: '.apps-button, [aria-label="Apps"], puter-user-menu { display: none !important; }',
              hideLabels: ['Sign in with Puter', 'Open from Puter', 'Open from Puter…', 'From Puter…', 'Save a copy to Puter',
                           'Save to another Puter folder…'],
              // Save and ⌘S download the PDF, with a save panel from Thermo.
              redirect: { from: /^(Sign in to save|Save to Puter|Save)$/, to: '.download-btn', shortcut: { key: 's', shift: false } },
              relabel: { 'Sign in to save': 'Save', 'Save to Puter': 'Save' },
              text: [
                [/Work locally, or sign in to save PDFs in your Puter cloud\./, 'PDFs are opened and saved on this Mac.'],
                [/Sign in with Puter to save and access your files across devices\./, 'Open a PDF to start.'],
                [/Open a PDF and save it to Puter to find it here\./, 'PDFs you open appear here.'],
                [/Cloud files are (saved in your Puter account|stored through Puter)\./, 'Nothing is uploaded.'],
                [/This PDF is not saved anywhere yet\. Sign in to Puter to save it to your own cloud, or leave and discard the changes\./,
                 'This PDF is not saved yet. Download it first, or leave and discard the changes.'],
              ],
            }
            """#
        case .photoStudio:
            let cloud = ["app.account", "file.open-cloud", "file.save-as", "file.save-copy", "file.save-version", "file.version-history",
                         "file.place-linked-cloud", "file.import-layers-cloud", "file.scripts-browse-cloud",
                         "edit.generate-image", "edit.edit-with-prompt", "edit.ai-fill", "edit.ai-expand", "edit.ai-recompose",
                         "edit.remove-reflections", "edit.rotate-object", "layer.harmonize", "layer.mask-all-objects",
                         "assistant.ask", "assistant.clear", "assistant.see-image"]
            let selectors = cloud.map { "[data-command=\"\($0)\"]" } + [".start-describe", "[data-panel-tab=\"assistant\"]",
                "[data-panel-tab=\"generations\"]", "[data-strip-panel=\"assistant\"]", "[data-strip-panel=\"generations\"]",
                ".statusbar a[href*=\"puter.com\"]"]
            config = """
            {
              css: '\(selectors.joined(separator: ", ")) { display: none !important; }',
              hideLabels: ['Open from Puter…', 'Browse Puter…', 'From Puter…'],
              // Save writes the layered .photo project to a file on this Mac.
              command: { 'file.save': 'file.download-project' },
              commandTitle: { 'file.save': 'Save to this Mac' },
              shortcutCommand: { key: 's', shift: false, command: 'file.download-project' },
              text: [],
            }
            """
        case .timeTracking:
            config = #"""
            {
              css: '',
              hideLabels: ['Sign out', 'Back up now'],
              text: [
                [/Stored in your own Puter account, never sold or shared\./, 'Stored on this Mac, never uploaded.'],
                [/Synced with your Puter cloud/, 'Stored on this Mac'],
                [/Stored in your own Puter files/, 'Stored on this Mac'],
                [/^Puter user$/, 'This Mac'],
              ],
            }
            """#
        }
        return "(\(Self.offlineRuntime))(\(config));"
    }

    /// Shared by all apps; `cfg` is the app's literal above.
    private static let offlineRuntime = #"""
    (cfg) => {
      const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
      const label = (el) => norm(el.getAttribute('aria-label') || el.textContent);
      const clickables = 'button, a, [role="menuitem"], [role="button"], li';
      const hidden = new Set(cfg.hideLabels || []);
      const sweep = (root) => {
        if (!(root instanceof Element)) return;
        for (const el of [root, ...root.querySelectorAll(clickables)]) {
          if (!el.matches || !el.matches(clickables)) continue;
          if (hidden.has(label(el))) el.style.setProperty('display', 'none', 'important');
          if (cfg.command && el.dataset && cfg.command[el.dataset.command]) {
            const from = el.dataset.command;
            el.dataset.command = cfg.command[from];
            if (cfg.commandTitle && cfg.commandTitle[from]) el.title = cfg.commandTitle[from];
          }
        }
        if (cfg.relabel) for (const el of [root, ...root.querySelectorAll('button span, button')]) {
          if (el.children.length) continue;
          const to = cfg.relabel[norm(el.textContent)];
          if (to) el.textContent = to;
        }
        if (cfg.text.length) {
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          for (let node; (node = walker.nextNode()); ) {
            for (const [re, to] of cfg.text) if (re.test(node.nodeValue)) node.nodeValue = node.nodeValue.replace(re, to);
          }
        }
      };
      const start = () => {
        if (cfg.css) { const style = document.createElement('style'); style.textContent = cfg.css; document.head.append(style); }
        sweep(document.body);
        new MutationObserver((records) => {
          for (const r of records) {
            if (r.type === 'characterData') sweep(r.target.parentElement);
            else for (const n of r.addedNodes) sweep(n.nodeType === 3 ? n.parentElement : n);
          }
        }).observe(document.body, { childList: true, subtree: true, characterData: true });
      };
      if (cfg.redirect) {
        const redirect = (event) => {
          const target = document.querySelector(cfg.redirect.to);
          if (!target) return false;
          event.preventDefault(); event.stopImmediatePropagation();
          target.click();
          return true;
        };
        document.addEventListener('click', (event) => {
          const el = event.target.closest && event.target.closest('button');
          if (el && !el.matches(cfg.redirect.to) && cfg.redirect.from.test(label(el))) redirect(event);
        }, true);
        document.addEventListener('keydown', (event) => {
          const s = cfg.redirect.shortcut;
          if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === s.key && event.shiftKey === s.shift) redirect(event);
        }, true);
      }
      if (cfg.shortcutCommand) {
        document.addEventListener('keydown', (event) => {
          const s = cfg.shortcutCommand;
          if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== s.key || event.shiftKey !== s.shift || event.altKey) return;
          const button = document.querySelector('[data-command="' + s.command + '"]');
          if (!button) return;
          event.preventDefault(); event.stopImmediatePropagation();
          button.click();
        }, true);
      }
      if (document.body) start(); else document.addEventListener('DOMContentLoaded', start, { once: true });
    }
    """#
}
