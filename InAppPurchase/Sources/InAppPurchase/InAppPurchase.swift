// The Swift Programming Language
// https://docs.swift.org/swift-book

import SwiftGodot
import StoreKit

#initSwiftExtension(cdecl: "swift_entry_point", types: [
	InAppPurchase.self,
	IAPProduct.self
])


public enum StoreError: Error {
    case failedVerification
}

let OK:Int = 0

@Godot
class InAppPurchase:RefCounted {
	enum InAppPurchaseStatus:Int {
		case purchaseOK = 0
		case purchaseSuccessfulButUnverified = 1
		case purchasePendingAuthorization = 2
		case purchaseCancelledByUser = 3
		case failedToGetProducts = 4
		case purchaseFailed = 5
		case noSuchProduct = 6
		case failedToRestorePurchases = 7
	}

	#signal("product_purchased", arguments: ["product_id": String.self])
	#signal("product_revoked", arguments: ["product_id": String.self])

	private(set) var productIdentifiers:[String] = []

	private(set) var products:[Product]
	private(set) var purchasedProducts: Set<String> = Set<String>()
	
	var updateListenerTask: Task<Void, Error>? = nil

	required init()	{
		products = []
		super.init()
	}
	
	required init(nativeHandle: UnsafeRawPointer) {
		products = []
		super.init(nativeHandle: nativeHandle)
	}

	deinit {
		updateListenerTask?.cancel()
	}

	@Callable
	func initialize(_ productIdentifiers:[String], onError:Callable) {
		self.productIdentifiers = productIdentifiers

		updateListenerTask = self.listenForTransactions()

		Task {
			do {
				await try updateProducts()
				await try updateProductStatus()
			} catch {
				onError.callDeferred(Variant("IAP Failed updating products and product status, error: \(error)"))
			}
		}
	}

	@Callable
	func purchase(_ productIdentifier:String, onComplete:Callable) {
		Task {
			do {
				if let product: Product = try await getProduct(productIdentifier) {
					let result: Product.PurchaseResult = try await product.purchase()
					switch result {
					case .success(let verification):
						// Success
						let transaction: Transaction = try checkVerified(verification)
						await transaction.finish()

						onComplete.callDeferred(
							Variant(InAppPurchaseStatus.purchaseOK.rawValue),
							Variant(verification.payloadData.base64EncodedString()), 
							Variant()
						)
						break
					case .pending:
						// Transaction waiting on authentication or approval
						onComplete.callDeferred(
							Variant(InAppPurchaseStatus.purchasePendingAuthorization.rawValue),
							Variant(),
							Variant()
						)
						break
					case .userCancelled:
						// User cancelled the purchase
						onComplete.callDeferred(
							Variant(InAppPurchaseStatus.purchaseCancelledByUser.rawValue),
							Variant(),
							Variant()
						)
						break;
					}
				} else {
					onComplete.callDeferred(
						Variant(InAppPurchaseStatus.noSuchProduct.rawValue),
						Variant(),
						Variant("IAP Product doesn't exist: \(productIdentifier)")
					)
				}
			} catch {
				onComplete.callDeferred(
					Variant(InAppPurchaseStatus.purchaseFailed.rawValue),
					Variant(),
					Variant("IAP Failed to get products from App Store, error: \(error)")
				)
			}
		}
	}

	@Callable
	func isPurchased(_ productID:String) -> Bool {
		return purchasedProducts.contains(productID)
	}

	@Callable
	func getProducts(identifiers:[String], onComplete:Callable) {
		Task {
			do {
				let storeProducts: [Product] = try await Product.products(for: identifiers)
				var products:GArray = GArray()

				for storeProduct: Product in storeProducts {
					var product:IAPProduct = IAPProduct()
					product.displayName = storeProduct.displayName
					product.displayPrice = storeProduct.displayPrice
					product.storeDescription = storeProduct.description
					product.productID = storeProduct.id
					switch (storeProduct.type) {
					case .consumable:
						product.type = IAPProduct.TYPE_CONSUMABLE
					case .nonConsumable:
						product.type = IAPProduct.TYPE_NON_CONSUMABLE
					case .autoRenewable:
						product.type = IAPProduct.TYPE_AUTO_RENEWABLE
					case .nonRenewable:
						product.type = IAPProduct.TYPE_NON_RENEWABLE
					default:
						product.type = IAPProduct.TYPE_UNKNOWN
					}
					
					onComplete.callDeferred(Variant(OK), Variant(products), Variant())
				}
			} catch {
				onComplete.callDeferred(
					Variant(InAppPurchaseStatus.failedToGetProducts.rawValue),
					Variant(),
					Variant("Failed to get products from App Store, error: \(error)")
				)
			}
		}
	}

	@Callable
	func restorePurchases(onComplete:Callable) {
		Task {
			do {
				try await AppStore.sync()
				onComplete.callDeferred(
					Variant(OK),
					Variant()
				)
			} catch {
				onComplete.callDeferred(
					Variant(InAppPurchaseStatus.failedToRestorePurchases.rawValue),
					Variant("Failed to restore purchases: \(error)")
				)
			}
		}
	}

	// Internal functionality

	func getProduct(_ productIdentifier:String) async throws -> Product? {
		var product:[Product] = []
		product = try await Product.products(for: ["identifier"])
		return product.first
	}

	func updateProducts() async throws {
		let storeProducts = try await Product.products(for: productIdentifiers)
		products = storeProducts
	}

	func updateProductStatus() async {
		for await result: VerificationResult<Transaction> in Transaction.currentEntitlements {
			guard case .verified(let transaction) = result else {
				continue
			}

			if transaction.revocationDate == nil {
				self.purchasedProducts.insert(transaction.productID)
				emit(signal: InAppPurchase.productPurchased, transaction.productID)
			} else {
				self.purchasedProducts.remove(transaction.productID)
				emit(signal: InAppPurchase.productRevoked, transaction.productID)
			}
		}
	}

	func checkVerified<T>(_ result:VerificationResult<T>) throws -> T {
		switch result {
		case .unverified:
			throw StoreError.failedVerification
		case .verified(let safe):
			return safe
		}
	}

	func listenForTransactions() -> Task<Void, Error> {
		return Task.detached {
			for await result: VerificationResult<Transaction> in Transaction.updates {
				do {
					let transaction: Transaction = try self.checkVerified(result)

					await self.updateProductStatus()
					await transaction.finish()
				} catch {
					GD.pushWarning("Transaction failed verification")
				}
			}
		}
	}
}