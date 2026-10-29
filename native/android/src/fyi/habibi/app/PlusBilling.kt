package fyi.habibi.app

import android.app.Activity
import android.os.Handler
import android.os.Looper
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import org.json.JSONObject

/** Google Play owns payment; only the authenticated server grants Plus. No vault access. */
internal class PlusBilling(private val activity: Activity, private val session: HabibiSession, private val changed: () -> Unit) {
    companion object { val productIds = listOf("habibi_plus_monthly", "habibi_plus_yearly") }
    data class Plan(val product: ProductDetails, val offer: ProductDetails.SubscriptionOfferDetails, val price: String)
    var plans: List<Plan> = emptyList(); private set
    var busy = false; private set
    var message: String? = null; private set
    var selected = productIds[1]
    private var closed = false
    private var connecting = false
    private val processing = mutableSetOf<String>()
    private val handler = Handler(Looper.getMainLooper())
    private val availabilityTimeout = Runnable {
        if (!closed) {
            connecting = false; busy = processing.isNotEmpty()
            message = "Google Play did not respond. Refresh availability to retry. Nothing has been charged."
            changed()
        }
    }
    private val client = BillingClient.newBuilder(activity)
        .setListener { result, purchases ->
            handler.post {
                if (!closed) when (result.responseCode) {
                    BillingClient.BillingResponseCode.OK -> purchases.orEmpty().forEach(::deliver)
                    BillingClient.BillingResponseCode.USER_CANCELED -> { busy = false; changed() }
                    else -> { busy = false; message = "Google Play could not complete the purchase. Restore purchases before trying to pay again."; changed() }
                }
            }
        }
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .enableAutoServiceReconnection()
        .build()

    fun load() {
        if (closed || connecting) return
        if (client.isReady) { queryPlans(); return }
        connecting = true; busy = true; message = null; changed()
        handler.postDelayed(availabilityTimeout, 15_000)
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingServiceDisconnected() {
                handler.post {
                    if (!closed) { handler.removeCallbacks(availabilityTimeout); connecting = false; busy = processing.isNotEmpty(); message = "Google Play is disconnected. Refresh availability to retry."; changed() }
                }
            }
            override fun onBillingSetupFinished(result: BillingResult) {
                handler.post {
                    if (closed) return@post
                    handler.removeCallbacks(availabilityTimeout)
                    connecting = false; busy = false
                    if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                        queryPlans()
                        if (session.syncConnected) restore()
                    } else { message = "Subscriptions aren’t available from Google Play on this device. Nothing has been charged."; changed() }
                }
            }
        })
    }

    private fun queryPlans() {
        busy = true; changed()
        handler.removeCallbacks(availabilityTimeout)
        handler.postDelayed(availabilityTimeout, 15_000)
        val products = productIds.map { QueryProductDetailsParams.Product.newBuilder().setProductId(it).setProductType(BillingClient.ProductType.SUBS).build() }
        client.queryProductDetailsAsync(QueryProductDetailsParams.newBuilder().setProductList(products).build()) { result, details ->
            handler.post {
                if (closed) return@post
                handler.removeCallbacks(availabilityTimeout)
                busy = processing.isNotEmpty()
                plans = if (result.responseCode == BillingClient.BillingResponseCode.OK) details.productDetailsList.mapNotNull { product ->
                    // Only ordinary auto-renewing base plans. Never label a trial's zero price as the recurring price.
                    val period = if (product.productId == productIds[0]) "P1M" else "P1Y"
                    val offer = product.subscriptionOfferDetails?.firstOrNull { offer ->
                        offer.offerId == null && offer.pricingPhases.pricingPhaseList.singleOrNull()?.let {
                            it.billingPeriod == period && it.priceAmountMicros > 0 && it.recurrenceMode == ProductDetails.RecurrenceMode.INFINITE_RECURRING
                        } == true
                    } ?: return@mapNotNull null
                    Plan(product, offer, offer.pricingPhases.pricingPhaseList.single().formattedPrice)
                }.sortedBy { productIds.indexOf(it.product.productId) } else emptyList()
                if (plans.isEmpty()) message = "Google Play plans are unavailable. Nothing has been charged."
                if (plans.none { it.product.productId == selected }) selected = plans.firstOrNull()?.product?.productId ?: productIds[1]
                changed()
            }
        }
    }

    fun purchase() {
        val plan = plans.firstOrNull { it.product.productId == selected } ?: return
        if (closed || busy || processing.isNotEmpty() || !client.isReady || !session.syncConnected || session.plusActive) return
        busy = true; message = null; changed()
        session.subscriptionAccount { result ->
            if (closed) return@subscriptionAccount
            result.fold(onSuccess = { subject ->
                if (session.plusActive) { busy = false; changed(); return@fold }
                val product = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(plan.product).setOfferToken(plan.offer.offerToken).build()
                val params = BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(product))
                    .setObfuscatedAccountId(digest(subject.toByteArray(Charsets.UTF_8))).build()
                val response = client.launchBillingFlow(activity, params)
                if (response.responseCode != BillingClient.BillingResponseCode.OK) {
                    busy = false; message = "Google Play could not open checkout. Restore purchases if you already paid."; changed()
                }
            }, onFailure = { busy = false; message = it.message; changed() })
        }
    }

    fun restore() {
        if (closed || !client.isReady || !session.syncConnected) return
        client.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build()) { result, purchases ->
            handler.post {
                if (closed) return@post
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    purchases.forEach(::deliver)
                    session.refreshSubscription()
                    if (purchases.isEmpty()) { message = "No Google Play purchases found. Plus may be subscribed through another store or Habibi account."; changed() }
                } else { message = "Could not restore purchases. Retry when Google Play is available."; changed() }
            }
        }
    }

    private fun deliver(purchase: Purchase) {
        val product = purchase.products.singleOrNull()?.takeIf { it in productIds } ?: return
        if (purchase.purchaseState == Purchase.PurchaseState.PENDING) {
            busy = false; message = "Payment awaiting approval. Plus activates only after Google Play confirms payment."; changed(); return
        }
        if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED || !session.syncConnected || !processing.add(purchase.purchaseToken)) return
        busy = true; changed()
        session.subscriptionAccount { account ->
            if (closed) return@subscriptionAccount
            val subject = account.getOrNull()
            val owner = purchase.accountIdentifiers?.obfuscatedAccountId
            if (subject == null || (owner != null && owner != digest(subject.toByteArray(Charsets.UTF_8)))) {
                processing.remove(purchase.purchaseToken); busy = processing.isNotEmpty()
                message = "Sign in to the Habibi account that purchased Plus, then restore purchases."; changed(); return@subscriptionAccount
            }
            val receipt = JSONObject().put("platform", "android").put("product_id", product).put("fetch_token", purchase.purchaseToken)
            session.submitSubscriptionReceipt(receipt) { result ->
                if (closed) return@submitSubscriptionReceipt
                processing.remove(purchase.purchaseToken); busy = processing.isNotEmpty()
                if (result.isSuccess && session.plusActive) {
                    if (!purchase.isAcknowledged) {
                        client.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build()) { acknowledged ->
                            handler.post {
                                if (!closed && acknowledged.responseCode != BillingClient.BillingResponseCode.OK) {
                                    message = "Plus is verified. Purchase acknowledgement is pending; restore purchases to retry."; changed()
                                }
                            }
                        }
                    }
                    message = "Habibi Plus is ready. Your content stays encrypted."
                } else { message = "Purchase verification did not finish. Restore purchases to retry without paying again." }
                changed()
            }
        }
    }

    fun close() { closed = true; handler.removeCallbacks(availabilityTimeout); client.endConnection() }
}
