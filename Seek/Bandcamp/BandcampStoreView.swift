import SwiftUI
import WebKit

/// A release to open in the store; with a price, Seek buys it at that price in one go, once
/// confirmed.
struct StorePurchase: Identifiable {
    let result: BandcampAPI.StoreResult
    var price: BandcampAPI.Price?
    /// Library songs Bandcamp's copy replaces once it downloads (buying a library album).
    var replacing: [String] = []
    var id: Int { result.id }
}

/// A release page on Bandcamp. Purchases happen on Bandcamp's own page, signed in with the
/// same session as Seek's Bandcamp login, so Seek never sees payment details. Seek fills in the
/// buy dialog at the minimum price and presses Check out now. With `buyNow` (the Buy button in
/// search results) it also presses the final pay button, but only when the checkout total matches
/// that price; otherwise it stops on the checkout page for the user. Once Bandcamp adds the
/// release to the collection, Seek downloads it into the library.
struct BandcampStoreView: View {
    let result: BandcampAPI.StoreResult
    @State private var buyNow: BandcampAPI.Price?
    /// Library songs the purchase replaces, set up once it's confirmed.
    private let replacing: [String]
    /// The seller takes PayPal only: the page is shown to pay there, rather than paying in one tap.
    private let paypalOnly: Bool
    /// A one-tap purchase waits on the confirmation screen; the page only loads once it's given.
    @State private var confirmed: Bool
    @Environment(BandcampClient.self) private var bandcamp
    @Environment(\.dismiss) private var dismiss
    @State private var checkout = StoreCheckout()
    /// One-tap purchases run with the page hidden behind a progress view; it's shown if Seek
    /// needs the user to finish, or straight away for "Open on Bandcamp".
    @State private var showPage: Bool

    init(result: BandcampAPI.StoreResult, buyNow: BandcampAPI.Price? = nil, replacing: [String] = []) {
        self.result = result
        self.replacing = replacing
        // Sellers taking PayPal only are paid on the page: one tap uses a saved card.
        paypalOnly = buyNow?.paypalOnly == true
        // Free releases ("name your price" from nothing) go to the page, where you choose.
        let buyNow = (buyNow?.amount ?? 0) > 0 && !paypalOnly ? buyNow : nil
        _buyNow = State(initialValue: buyNow)
        _showPage = State(initialValue: buyNow == nil)
        _confirmed = State(initialValue: buyNow == nil)
    }

    var body: some View {
        if confirmed {
            store
        } else {
            PurchaseConfirmation(result: result, price: buyNow, replacesSongs: !replacing.isEmpty) {
                withAnimation(.smooth) { confirmed = true }
            } payMore: {
                // To Bandcamp's own page to choose the amount there.
                buyNow = nil
                showPage = true
                confirmed = true
            } cancel: {
                dismiss()
            }
            .transition(.opacity)
        }
    }

    private var store: some View {
        NavigationStack {
            ZStack {
                // Straight to checkout only when it's something to buy and the purchase will reach Seek.
                // Kept on screen (nearly transparent) while hidden: WebKit pauses pages that aren't.
                StoreWebView(url: result.url, checkout: checkout,
                             autoCheckout: bandcamp.isSignedIn && bandcamp.owned(result) == nil,
                             buyNow: buyNow) {
                    Task { await bandcamp.checkForPurchase(of: result) }
                }
                .ignoresSafeArea(edges: .bottom)
                .opacity(showPage ? 1 : 0.01)
                .allowsHitTesting(showPage)

                if !showPage {
                    PurchaseProgressView(result: result, price: buyNow, checkout: checkout) {
                        withAnimation { showPage = true }
                    }
                    .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { if showPage { banner } }
            .navigationTitle(showPage ? result.title : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            bandcamp.watchForPurchase(of: result)
            if !replacing.isEmpty { bandcamp.replace(replacing, with: result) }
        }
    }

    @ViewBuilder private var banner: some View {
        let item = bandcamp.owned(result)
        let download = item.flatMap { bandcamp.download(for: $0) }
        HStack(spacing: 8) {
            if !bandcamp.isSignedIn {
                Image(systemName: "exclamationmark.triangle")
                Text("Sign in to Bandcamp in Settings so purchases download to your library.")
            } else if let download {
                Image(systemName: download.state == .completed ? "checkmark.circle.fill" : "arrow.down.circle")
                Text(download.state == .completed ? "In your library" : "Purchased · \(download.state.label)")
            } else if item != nil {
                Image(systemName: "checkmark.circle.fill")
                Text("In your Bandcamp collection")
            } else {
                switch checkout.state {
                case .preparing:
                    ProgressView().controlSize(.small)
                    Text("Going to checkout…")
                case .checkingOut(let price):
                    Image(systemName: "cart")
                    Text(checkout.willPay ? "Buying for \(price)…" : "Checking out at the minimum, \(price). Place the order below.")
                    Spacer(minLength: 4)
                    Button("Change Amount") { checkout.changeAmount() }
                        .font(.footnote.weight(.semibold))
                case .paid(let total):
                    ProgressView().controlSize(.small)
                    Text("Ordered for \(total) including any tax. Waiting for Bandcamp to confirm…")
                case .stopped(let reason):
                    Image(systemName: "hand.raised")
                    Text("\(reason) Finish the order below.")
                case .enterPrice:
                    Image(systemName: "cart")
                    Text("Enter an amount, then Check out now. It downloads to your library once Bandcamp confirms.")
                case .browsing:
                    Image(systemName: "cart")
                    Text(paypalOnly
                         ? "This seller only takes PayPal, so pay below. It downloads to your library once Bandcamp confirms."
                         : "Buy below. It downloads to your library once Bandcamp confirms.")
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Drives Bandcamp's buy dialog in the store web view.
@MainActor
@Observable
final class StoreCheckout {
    enum State: Equatable {
        case browsing
        case preparing
        /// On Bandcamp's checkout page, paying this formatted price.
        case checkingOut(String)
        /// The dialog is open for the user to type an amount (name-your-price from zero, or by request).
        case enterPrice
        /// Seek pressed the final pay button for this total.
        case paid(String)
        /// Seek didn't press pay, for this reason; the user finishes the order.
        case stopped(String)
    }

    var state = State.browsing
    /// Set when checkout couldn't start on the page in time.
    private(set) var gaveUp = false
    /// The amount to pay without asking, from the Buy button in search results.
    @ObservationIgnored private var payAmount: Double?
    var willPay: Bool { payAmount != nil }
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored private var releaseURL: URL?
    /// What to do when the release page next finishes loading.
    @ObservationIgnored private var pending: Mode?

    enum Mode { case checkout, enterPrice }

    func start(at url: URL, autoCheckout: Bool, buyNow: BandcampAPI.Price?) {
        releaseURL = url
        payAmount = autoCheckout ? buyNow?.amount : nil
        if autoCheckout {
            pending = .checkout
            prepare()
        }
    }

    /// Shows progress, giving up after a while so a page Seek can't drive is left to the user.
    private func prepare() {
        state = .preparing
        Task {
            try? await Task.sleep(for: .seconds(20))
            if state == .preparing {
                pending = nil
                gaveUp = true
                state = .browsing
            }
        }
    }

    /// Back to the release page with the dialog open, for paying more than the minimum.
    func changeAmount() {
        guard let webView, let releaseURL else { return }
        payAmount = nil
        pending = .enterPrice
        prepare()
        webView.load(URLRequest(url: releaseURL))
    }

    func pageLoaded(_ webView: WKWebView) {
        guard let url = webView.url, let releaseURL else { return }
        Log.debug("bandcamp store page: \(url) state: \(state) paying: \(String(describing: payAmount))")
        if url.path() == releaseURL.path() {
            guard let mode = pending else { return }
            pending = nil
            Task { await run(mode, in: webView) }
        } else if payAmount != nil, case .checkingOut = state {
            Task { await pay(in: webView) }
        }
    }

    private func run(_ mode: Mode, in webView: WKWebView) async {
        let arguments: [String: Any] = ["enterPrice": mode == .enterPrice, "amount": payAmount ?? -1]
        let outcome = try? await webView.callAsyncJavaScript(
            Self.script, arguments: arguments, contentWorld: .page
        ) as? [String: Any]
        let status = outcome?["status"] as? String
        Log.debug("bandcamp checkout: \(outcome ?? [:])")
        switch status {
        case "checkout":
            state = .checkingOut(outcome?["price"] as? String ?? "")
            if payAmount != nil {
                // A checkout that never reaches the pay button (e.g. a reCAPTCHA puzzle) is handed over.
                Task {
                    try? await Task.sleep(for: .seconds(45))
                    if case .checkingOut = state, payAmount != nil { stop("Bandcamp's checkout didn't finish.") }
                }
            }
            // Bandcamp may show checkout in the same page rather than loading a new one.
            if payAmount != nil {
                try? await Task.sleep(for: .seconds(1.5))
                if case .checkingOut = state { await pay(in: webView) }
            }
        case "enterPrice":
            state = .enterPrice
        default:
            // The buy button or dialog wasn't found: say so (with a way to finish on the page)
            // rather than looking as if checkout were still on its way.
            gaveUp = true
            state = .browsing
        }
    }

    /// Presses the checkout page's pay button if the page's total is exactly the agreed price.
    private func pay(in webView: WKWebView) async {
        guard let amount = payAmount, let url = webView.url, !(url.host() ?? "").contains("paypal") else {
            if payAmount != nil { stop("Bandcamp sent you to PayPal.") }
            return
        }
        let outcome: [String: Any]
        do {
            outcome = try await webView.callAsyncJavaScript(
                Self.payScript, arguments: ["expected": amount], contentWorld: .page
            ) as? [String: Any] ?? [:]
        } catch {
            // The page changed while looking; the next page load tries again.
            Log.debug("bandcamp pay script failed at \(url): \(error)")
            return
        }
        Log.debug("bandcamp pay at \(url): \(outcome)")
        guard case .checkingOut = state else { return }
        switch outcome["status"] as? String {
        case "paid":
            payAmount = nil
            state = .paid(outcome["total"] as? String ?? "")
        case "busy":
            break
        case "totalMismatch":
            stop("The checkout total is more than the Buy button's price plus tax, so Seek didn't pay.")
        case "noTotal":
            stop("Seek couldn't read a single total for just this release, so it didn't pay.")
        default:
            // Only a PayPal button: the seller doesn't take cards (true of some sellers' every release).
            let buttons = outcome["buttons"] as? [String] ?? []
            if buttons.contains(where: { $0.localizedCaseInsensitiveContains("paypal") }) {
                stop("This seller only takes PayPal, so Seek can't pay with your saved card.")
            } else {
                stop("Seek couldn't find a pay button with a saved payment method.")
            }
        }
    }

    private func stop(_ reason: String) {
        payAmount = nil
        state = .stopped(reason)
    }

    /// Finds the final pay button (not PayPal, a card form or Apple/Google Pay) and the order total,
    /// and presses the button only when the order is just this release, priced at `expected` plus at most sales tax.
    static let payScript = """
        if (window.__seekPaying) return { status: 'busy' };
        window.__seekPaying = true;
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const visible = e => e && e.offsetParent !== null;
        const text = e => (e.innerText || e.value || '').replace(/\\s+/g, ' ').trim();
        const money = t => (t.match(/\\d[\\d.,]*/g) || []).map(s => {
            s = /,\\d{2}$/.test(s) ? s.replace(/\\./g, '').replace(',', '.') : s.replace(/,/g, '');
            return parseFloat(s);
        });
        const payPattern = /^(complete|place|confirm|submit|finish)\\b.*\\b(purchase|order|payment)\\b|^pay( now)?\\b|^buy now\\b/i;
        const avoid = /paypal|apple pay|google pay|pay with|with card|new card|add card|cancel|back/i;
        const candidates = () => [...document.querySelectorAll('button, input[type=submit], [role=button], a.button')]
            .filter(e => visible(e) && !e.disabled && payPattern.test(text(e)) && !avoid.test(text(e)));
        let buttons = [];
        for (let t = 0; t < 10000 && !buttons.length; t += 250) { buttons = candidates(); if (!buttons.length) await sleep(250); }
        const diagnostics = {
            url: location.href,
            buttons: [...document.querySelectorAll('button, input[type=submit], [role=button], a.button')]
                .filter(visible).map(text).filter(t => t).slice(0, 30),
            frames: [...document.querySelectorAll('iframe')].filter(visible).map(f => f.src).slice(0, 10),
            dialogs: [...document.querySelectorAll('.ui-dialog, [role=dialog]')].filter(visible).map(d => text(d).slice(0, 300)),
        };
        if (buttons.length !== 1) { window.__seekPaying = false; return { status: 'noButton', ...diagnostics }; }
        // Prices on the page, e.g. "$2.48" (not "(approximately €2.21 EUR)"), and the items in the order.
        // An element's text includes its children's, so "$2.48 USD" is found even when "USD" is its own span.
        // Bandcamp's converted estimate, "(approximately €2.21 EUR)", isn't what's charged.
        const estimate = e => e.parentElement && /approx/i.test(text(e.parentElement));
        const priceTexts = [...new Set([...document.querySelectorAll('body *')]
            .filter(e => visible(e) && !estimate(e)).map(text)
            .filter(t => t.length < 30 && /^[^\\d(]{0,3}\\d[\\d.,]*[.,]\\d{2}( ?[A-Z]{3})?$/.test(t)))];
        const amounts = [...new Set(priceTexts.map(t => money(t)[0]))];
        const items = new Set([...document.querySelectorAll('body *')].filter(e => visible(e) && !e.children.length)
            .filter(e => /^digital (track|album)$/i.test(text(e)))).size;
        diagnostics.prices = priceTexts;
        diagnostics.items = items;
        if (amounts.length !== 1 || items > 1) { window.__seekPaying = false; return { status: 'noTotal', ...diagnostics }; }
        // The total may add sales tax (up to 27%, the highest EU VAT rate) to the price shown in Seek.
        const total = amounts[0];
        if (!(total >= expected - 0.005 && total <= expected * 1.27 + 0.005)) {
            window.__seekPaying = false;
            return { status: 'totalMismatch', ...diagnostics };
        }
        buttons[0].click();
        return { status: 'paid', pressed: text(buttons[0]), total: priceTexts[0], ...diagnostics };
        """

    /// Opens the digital buy dialog, fills in the minimum price and presses Check out now. With a
    /// zero minimum (or `enterPrice`), it stops at the price field instead.
    static let script = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const visible = e => e && e.offsetParent !== null;
        async function waitFor(find, ms = 6000) {
            for (let t = 0; t < ms; t += 100) { const e = find(); if (e) return e; await sleep(100); }
            return null;
        }
        // The desktop page has a "Buy Digital Album" link; the mobile page has a "Buy Album" (or, with
        // physical formats too, "View purchase options") button, which goes straight to the price
        // dialog or first to a list of formats.
        const opener = await waitFor(() =>
            [...document.querySelectorAll('.buyItem.digital .buy-link')].find(b => visible(b) && /^buy/i.test(b.innerText.trim()))
            || [...document.querySelectorAll('.view-purchase-options-btn')].find(b => visible(b) && /^(buy|view purchase options)/i.test(b.innerText.trim())));
        if (!opener) return { status: 'unavailable' };
        let min = 0, currency = '';
        try {
            const data = JSON.parse(document.querySelector('[data-tralbum]').dataset.tralbum);
            min = data.current.minimum_price || 0;
        } catch (e) {}
        currency = document.querySelector('[data-band-currency]')?.dataset.bandCurrency
            || (opener.innerText.match(/\\b[A-Z]{3}\\b/) || [''])[0];
        opener.click();
        const panel = () => { const d = document.querySelector('#download-panel-vm'); return visible(d) ? d : null; };
        let dialog = await waitFor(panel, 1500);
        if (!dialog) {
            const digital = await waitFor(() => [...document.querySelectorAll('.buy-now')]
                .find(b => visible(b) && /digital/i.test(b.innerText)), 3000);
            if (!digital) return { status: 'unavailable' };
            digital.click();
            dialog = await waitFor(panel);
        }
        if (!dialog) return { status: 'unavailable' };
        const field = dialog.querySelector('#userPrice');
        if (visible(field)) {
            if (enterPrice || !(min > 0)) { field.focus(); field.select(); return { status: 'enterPrice' }; }
            field.focus();
            if (amount > 0) min = amount;
            field.value = String(min);
            field.dispatchEvent(new Event('input', { bubbles: true }));
            field.dispatchEvent(new Event('change', { bubbles: true }));
            field.dispatchEvent(new Event('blur', { bubbles: true }));
            await sleep(200);
        } else if (enterPrice) {
            return { status: 'enterPrice' };
        }
        const button = [...dialog.querySelectorAll('button')].find(b => visible(b) && /check out now/i.test(b.innerText));
        if (!button) return { status: 'enterPrice' };
        const price = new Intl.NumberFormat(undefined, currency ? { style: 'currency', currency } : {}).format(min);
        button.click();
        return { status: 'checkout', price };
        """
}

private struct StoreWebView: UIViewRepresentable {
    let url: URL
    let checkout: StoreCheckout
    let autoCheckout: Bool
    let buyNow: BandcampAPI.Price?
    let onNavigation: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(checkout: checkout, onNavigation: onNavigation)
    }

    func makeUIView(context: Context) -> WKWebView {
        // The default data store holds the Bandcamp login from Settings.
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = BandcampAPI.userAgent
        webView.allowsBackForwardNavigationGestures = true
        checkout.webView = webView
        checkout.start(at: url, autoCheckout: autoCheckout, buyNow: buyNow)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let checkout: StoreCheckout
        let onNavigation: () -> Void

        init(checkout: StoreCheckout, onNavigation: @escaping () -> Void) {
            self.checkout = checkout
            self.onNavigation = onNavigation
        }

        /// Each page change during checkout (e.g. the thank-you page) is a good moment to look
        /// for the purchase rather than waiting for the next timed check.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { checkout.pageLoaded(webView) }
            onNavigation()
        }

        /// Checkout and PayPal open new windows; keep them in this view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

/// A release for sale in search results.
struct BandcampStoreRow: View {
    let result: BandcampAPI.StoreResult
    /// Buys at the shown price in one go.
    var onBuy: ((BandcampAPI.Price) -> Void)?
    @Environment(BandcampClient.self) private var bandcamp

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 48, height: 48)
            .clipShape(.rect(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).lineLimit(2)
                // A heart before the artist marks wishlisted releases without taking a line of its own.
                HStack(spacing: 4) {
                    if bandcamp.isWishlisted(result) {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                            .accessibilityLabel("On your wishlist")
                    }
                    Text(result.isTrack ? "\(result.artist) · Track" : result.artist)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.subheadline)
                if bandcamp.awaitingPurchase.contains(result.id) {
                    Text("Waiting for purchase…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let item = bandcamp.owned(result), let download = bandcamp.download(for: item), download.state.isActive {
                ProgressRing(progress: download.ringProgress)
            } else if bandcamp.owned(result) != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else if let onBuy, bandcamp.isSignedIn, let price = bandcamp.prices[result.id], price.amount > 0 {
                Button(price.shortFormatted) { onBuy(price) }
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("Buy for \(price.formatted)")
            } else {
                Image(systemName: "cart").foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
        .task(id: result.id) {
            if onBuy != nil { await bandcamp.loadPrice(for: result) }
        }
    }
}

/// A one-tap purchase in progress, shown instead of the Bandcamp page: checkout, payment,
/// Bandcamp confirming, then the download into the library.
struct PurchaseProgressView: View {
    let result: BandcampAPI.StoreResult
    let price: BandcampAPI.Price?
    let checkout: StoreCheckout
    let showPage: () -> Void
    @Environment(BandcampClient.self) private var bandcamp
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Int, CaseIterable {
        case checkout, paying, confirming, downloading, done

        var label: String {
            switch self {
            case .checkout: "Going to checkout"
            case .paying: "Paying"
            case .confirming: "Waiting for Bandcamp"
            case .downloading: "Downloading"
            case .done: "In your library"
            }
        }
    }

    var body: some View {
        let (stage, stopped) = progress
        ScrollView {
            VStack(spacing: 18) {
                ReleaseArtwork(url: result.artworkURL.map(ReleaseDetailView.large), size: 200)
                    .shadow(radius: 10, y: 5)
                VStack(spacing: 4) {
                    Text(result.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(result.artist).font(.title3).foregroundStyle(.secondary)
                    if let price { Text(price.formatted).font(.headline).foregroundStyle(.tint).padding(.top, 2) }
                }

                if let stopped {
                    VStack(spacing: 12) {
                        Label(stopped, systemImage: "hand.raised.fill")
                            .multilineTextAlignment(.center)
                        if let item = bandcamp.owned(result), let download = bandcamp.download(for: item) {
                            Button("Try Again") { bandcamp.retry(download) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        } else {
                            Button("Finish on Bandcamp", action: showPage)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 14))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Stage.allCases, id: \.self) { step in
                            HStack(spacing: 12) {
                                Group {
                                    if step.rawValue < stage.rawValue || stage == .done {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else if step == stage {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "circle").foregroundStyle(.tertiary)
                                    }
                                }
                                .frame(width: 22)
                                Text(label(for: step))
                                    .foregroundStyle(step.rawValue <= stage.rawValue ? .primary : .secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))

                    Text(stage == .done ? "Ready to play." : "You can close this; the purchase and download carry on.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
    }

    private func label(for step: Stage) -> String {
        switch step {
        case .confirming:
            if case .paid(let total) = checkout.state, !total.isEmpty { return "Ordered for \(total) · waiting for Bandcamp" }
        case .downloading:
            if let item = bandcamp.owned(result), let download = bandcamp.download(for: item), download.state == .downloading {
                return "Downloading \(Int(download.progress * 100))%"
            }
        default: break
        }
        return step.label
    }

    /// Where the purchase is, or why Seek stopped.
    private var progress: (Stage, String?) {
        if let item = bandcamp.owned(result) {
            guard let download = bandcamp.download(for: item) else { return (.downloading, nil) }
            switch download.state {
            case .completed: return (.done, nil)
            case .failed(let reason): return (.downloading, "The download failed: \(reason)")
            default: return (.downloading, nil)
            }
        }
        switch checkout.state {
        case .preparing: return (.checkout, nil)
        case .checkingOut: return (.paying, nil)
        case .paid: return (.confirming, nil)
        case .stopped(let reason): return (.paying, reason)
        case .enterPrice: return (.checkout, "This release needs an amount entered on Bandcamp.")
        case .browsing: return (.checkout, checkout.gaveUp ? "Seek couldn't start checkout on this page." : nil)
        }
    }
}

/// Buying music is an occasion: the cover large over its own colours, the price, and one
/// button to buy it. Nothing is paid until that's pressed.
private struct PurchaseConfirmation: View {
    let result: BandcampAPI.StoreResult
    let price: BandcampAPI.Price?
    /// Buying a library album: Bandcamp's copy replaces the files once it downloads.
    let replacesSongs: Bool
    let buy: () -> Void
    let payMore: () -> Void
    let cancel: () -> Void
    @State private var appeared = false

    var body: some View {
        let cover = result.artworkURL.map(ReleaseDetailView.large)
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Cancel", systemImage: "xmark", action: cancel)
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.15), in: .circle)
                    .buttonStyle(.plain)
            }
            Spacer(minLength: 16)
            Color.white.opacity(0.08)
                .aspectRatio(1, contentMode: .fit)
                .overlay { RemoteImage(url: cover) { Color.clear } }
                .clipShape(.rect(cornerRadius: 14))
                .frame(maxWidth: 300)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .scaleEffect(appeared ? 1 : 0.85)
                .opacity(appeared ? 1 : 0)
            VStack(spacing: 6) {
                Text(result.title).font(.title.bold())
                Text(result.artist).font(.title3).foregroundStyle(.white.opacity(0.75))
            }
            .multilineTextAlignment(.center)
            .padding(.top, 28)
            Spacer(minLength: 24)
            VStack(spacing: 14) {
                Button(action: buy) {
                    Text(price.map { "Buy for \($0.formatted)" } ?? "Buy")
                        .font(.title3.bold())
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(.white, in: .capsule)
                }
                .buttonStyle(.plain)
                Text(replacesSongs
                     ? "Paid on Bandcamp with your saved card. Bandcamp's copy then replaces the files you have."
                     : "Paid on Bandcamp with your saved card, then added to your library.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button("Pay More on Bandcamp", action: payMore)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 2)
            }
            .frame(maxWidth: 420)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The cover's colours, blurred, behind everything, as in Now Playing. A background,
            // so the oversized image doesn't widen the page.
            ZStack {
                Color.black
                RemoteImage(url: cover) { Color.clear }
                    .blur(radius: 70, opaque: true)
                    .scaleEffect(1.4)
                    .opacity(0.9)
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(.spring(duration: 0.5, bounce: 0.25)) { appeared = true } }
    }
}
