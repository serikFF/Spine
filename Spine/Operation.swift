//
//  Operation.swift
//  Spine
//
//  Created by Ward van Teijlingen on 05-04-15.
//  Copyright (c) 2015 Ward van Teijlingen. All rights reserved.
//

import Foundation

private func statusCodeIsSuccess(statusCode: Int?) -> Bool {
	return statusCode != nil && 200 ... 299 ~= statusCode!
}

private func errorFromStatusCode(statusCode: Int, additionalErrors: [NSError]? = nil) -> NSError {
	let userInfo: [NSObject: AnyObject]?
	
	if let additionalErrors = additionalErrors {
		userInfo = ["apiErrors": additionalErrors]
	} else {
		userInfo = nil
	}
	
	return NSError(domain: SpineServerErrorDomain, code: statusCode, userInfo: userInfo)
}

// MARK: - Base operation

/**
The ConcurrentOperation class is an abstract class for all Spine operations.
You must not create instances of this class directly, but instead create
an instance of one of its concrete subclasses.

Subclassing
===========
To support generic subclasses, Operation adds an `execute` method.
Override this method to provide the implementation for a concurrent subclass.

Concurrent state
================
ConcurrentOperation is concurrent by default. To update the state of the operation,
update the `state` instance variable. This will fire off the needed KVO notifications.

Operating against a Spine
=========================
The `Spine` instance variable references the Spine against which to operate.
*/
class ConcurrentOperation: NSOperation {
	enum State: String {
		case Ready = "isReady"
		case Executing = "isExecuting"
		case Finished = "isFinished"
	}
	
	/// The current state of the operation
	var state: State = .Ready {
		willSet {
			willChangeValueForKey(newValue.rawValue)
			willChangeValueForKey(state.rawValue)
		}
		didSet {
			didChangeValueForKey(oldValue.rawValue)
			didChangeValueForKey(state.rawValue)
		}
	}
	override var ready: Bool {
		return super.ready && state == .Ready
	}
	override var executing: Bool {
		return state == .Executing
	}
	override var finished: Bool {
		return state == .Finished
	}
	override var asynchronous: Bool {
		return true
	}
	
	/// The Spine instance to operate against.
	var spine: Spine!
	
	/// Convenience variables that proxy to their spine counterpart
	var router: Router {
		return spine.router
	}
	var networkClient: NetworkClient {
		return spine.networkClient
	}
	var serializer: Serializer {
		return spine.serializer
	}
	
	override init() {}
	
	final override func start() {
		if self.cancelled {
			state = .Finished
		} else {
			state = .Executing
			main()
		}
	}
	
	final override func main() {
		execute()
	}
	
	func execute() {}
}


// MARK: - Main operations

/// FetchOperation fetches a JSONAPI document from a Spine, using a given Query.
class FetchOperation<T: Resource>: ConcurrentOperation {
	/// The query describing which resources to fetch.
	let query: Query<T>
	
	/// Existing resources onto which to map the fetched resources.
	var mappingTargets = [Resource]()
	
	/// The result of the operation. You can safely force unwrap this in the completionBlock.
	var result: Failable<JSONAPIDocument>?
	
	init(query: Query<T>, spine: Spine) {
		self.query = query
		super.init()
		self.spine = spine
	}
	
	override func execute() {
		let URL = spine.router.URLForQuery(query)
		
		Spine.logInfo(.Spine, "Fetching document using URL: \(URL)")
		
		networkClient.request("GET", URL: URL) { statusCode, responseData, networkError in
			defer { self.state = .Finished }
			
			guard networkError == nil else {
				self.result = Failable.Failure(networkError!)
				return
			}
			
			if let data = responseData where data.length > 0 {
				do {
					let document = try self.serializer.deserializeData(data, mappingTargets: self.mappingTargets)
					if statusCodeIsSuccess(statusCode) {
						self.result = Failable(document)
					} else {
						self.result = Failable.Failure(errorFromStatusCode(statusCode!, additionalErrors: document.errors))
					}
				} catch let error as NSError {
					self.result = Failable.Failure(error)
				}
				
			} else {
				self.result = Failable.Failure(errorFromStatusCode(statusCode!))
			}
		}
	}
}

/// DeleteOperation deletes a resource from a Spine.
class DeleteOperation: ConcurrentOperation {
	/// The resource to delete.
	let resource: Resource
	
	/// The result of the operation. You can safely force unwrap this in the completionBlock.
	var result: Failable<Void>?
	
	init(resource: Resource, spine: Spine) {
		self.resource = resource
		super.init()
		self.spine = spine
	}
	
	override func execute() {
		let URL = spine.router.URLForQuery(Query(resource: resource))
		
		Spine.logInfo(.Spine, "Deleting resource \(resource) using URL: \(URL)")
		
		networkClient.request("DELETE", URL: URL) { statusCode, responseData, networkError in
			defer { self.state = .Finished }
		
			guard networkError == nil else {
				self.result = Failable.Failure(networkError!)
				return
			}
			
			if statusCodeIsSuccess(statusCode) {
				self.result = Failable.Success()
			} else if let data = responseData where data.length > 0 {
				do {
					let document = try self.serializer.deserializeData(data, mappingTargets: nil)
					self.result = .Failure(errorFromStatusCode(statusCode!, additionalErrors: document.errors))
				} catch let error as NSError {
					self.result = .Failure(error)
				}
			} else {
				self.result = .Failure(errorFromStatusCode(statusCode!))
			}
		}
	}
}

/// A SaveOperation updates or adds a resource in a Spine.
class SaveOperation: ConcurrentOperation {
	/// The resource to save.
	let resource: Resource
	
	/// The result of the operation. You can safely force unwrap this in the completionBlock.
	var result: Failable<Void>?
	
	/// Whether the resource is a new resource, or an existing resource.
	private let isNewResource: Bool
	
	private let relationshipOperationQueue = NSOperationQueue()
	
	init(resource: Resource, spine: Spine) {
		self.resource = resource
		self.isNewResource = (resource.id == nil)
		super.init()
		self.spine = spine
		self.relationshipOperationQueue.maxConcurrentOperationCount = 1
	}
	
	override func execute() {
		// First update relationships if this is an existing resource. Otherwise the local relationships
		// are overwritten with data that is returned from saving the resource.
		if self.isNewResource {
			self.updateResource()
		} else {
			self.updateRelationships()
		}
	}

	private func updateResource() {
		let URL: NSURL
		let method: String
		let options: SerializationOptions
		
		if isNewResource {
			URL = router.URLForResourceType(resource.resourceType)
			method = "POST"
			options = [.IncludeToOne, .IncludeToMany]
		} else {
			URL = router.URLForQuery(Query(resource: resource))
			method = "PATCH"
			options = [.IncludeID]
		}
		
		let payload: NSData
		
		do {
			payload = try serializer.serializeResources([resource], options: options)
		} catch let error as NSError {
			self.result = Failable.Failure(error)
			self.state = .Finished
			return
		}
		
		Spine.logInfo(.Spine, "Saving resource \(resource) using URL: \(URL)")
		
		networkClient.request(method, URL: URL, payload: payload) { statusCode, responseData, networkError in
			defer { self.state = .Finished }
			
			guard networkError == nil else {
				self.result = Failable.Failure(networkError!)
				return
			}
			
			if(!statusCodeIsSuccess(statusCode)) {
				if let data = responseData where data.length > 0 {
					do {
						let document = try self.serializer.deserializeData(data, mappingTargets: nil)
						self.result = .Failure(errorFromStatusCode(statusCode!, additionalErrors: document.errors))
					} catch let error as NSError {
						self.result = .Failure(error)
					}
				} else {
					self.result = .Failure(errorFromStatusCode(statusCode!))
				}
			} else {
				if let data = responseData where data.length > 0 {
					do {
						try self.serializer.deserializeData(data, mappingTargets: [self.resource])
						self.result = .Success()
					} catch let error as NSError {
						self.result = .Failure(error)
					}
				} else {
					self.result = .Failure(errorFromStatusCode(statusCode!))
				}
			}
		}
	}

	private func updateRelationships() {
		self.relationshipOperationQueue.addObserver(self, forKeyPath: "operations", options: NSKeyValueObservingOptions(), context: nil)
		
		let completionHandler: (result: Failable<Void>?) -> Void = { result in
			if let error = result?.error {
				self.relationshipOperationQueue.cancelAllOperations()
				self.result = Failable(error)
			}
		}
		
		for field in resource.fields {
			switch field {
			case let toOne as ToOneRelationship:
				let operation = RelationshipReplaceOperation(resource: resource, relationship: toOne, spine: spine)
				operation.completionBlock = { [unowned operation] in completionHandler(result: operation.result) }
				relationshipOperationQueue.addOperation(operation)

			case let toMany as ToManyRelationship:
				let addOperation = RelationshipMutateOperation(resource: resource, relationship: toMany, mutation: .Add, spine: spine)
				addOperation.completionBlock = { [unowned addOperation] in completionHandler(result: addOperation.result) }
				relationshipOperationQueue.addOperation(addOperation)
				
				let removeOperation = RelationshipMutateOperation(resource: resource, relationship: toMany, mutation: .Remove, spine: spine)
				removeOperation.completionBlock = { [unowned removeOperation] in completionHandler(result: removeOperation.result) }
				relationshipOperationQueue.addOperation(removeOperation)
			default: ()
			}
		}
	}
	
	override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
		guard let path = keyPath, queue = object as? NSOperationQueue where path == "operations" && queue == relationshipOperationQueue else {
			super.observeValueForKeyPath(keyPath, ofObject: object, change: change, context: context)
			return
		}
		
		if queue.operationCount == 0 {
			// At this point, we know all relationships are updated
			self.updateResource()
		}
	}
}

private class RelationshipOperation: ConcurrentOperation {
	var result: Failable<Void>?
	
	func handleNetworkResponse(statusCode: Int?, responseData: NSData?, networkError: NSError?) {
		defer { self.state = .Finished }
		
		guard networkError == nil else {
			self.result = Failable.Failure(networkError!)
			return
		}
		
		if statusCodeIsSuccess(statusCode) {
			self.result = Failable.Success()
		} else if let data = responseData where data.length > 0 {
			do {
				let document = try serializer.deserializeData(data, mappingTargets: nil)
				self.result = .Failure(errorFromStatusCode(statusCode!, additionalErrors: document.errors))
			} catch let error as NSError {
				self.result = .Failure(error)
			}
		} else {
			self.result = .Failure(errorFromStatusCode(statusCode!))
		}
	}
	
	private func toOnePayload(resource: Resource?) throws -> NSData {
		let payloadData: AnyObject
		
		if let resource = resource {
			assert(resource.id != nil, "Attempt to convert resource without id to linkage. Only resources with ids can be converted to linkage.")
			payloadData = ["type": resource.resourceType, "id": resource.id!]
		} else {
			payloadData = NSNull()
		}
		
		return try NSJSONSerialization.dataWithJSONObject(["data": payloadData], options: NSJSONWritingOptions(rawValue: 0))
	}
	
	private func toManyPayload(resources: [Resource]) throws -> NSData {
		let payloadData: AnyObject
		
		if resources.isEmpty {
			payloadData = []
		} else {
			payloadData = resources.map { resource in
				return ["type": resource.resourceType, "id": resource.id!]
			}
		}
		
		return try NSJSONSerialization.dataWithJSONObject(["data": payloadData], options: NSJSONWritingOptions(rawValue: 0))
	}
}

/// A RelationshipReplaceOperation replaces the entire contents of a relationship.
private class RelationshipReplaceOperation: RelationshipOperation {
	let resource: Resource
	let relationship: Relationship

	init(resource: Resource, relationship: Relationship, spine: Spine) {
		self.resource = resource
		self.relationship = relationship
		super.init()
		self.spine = spine
	}
	
	override func execute() {
		let URL = router.URLForRelationship(relationship, ofResource: resource)
		let payload: NSData
		
		switch relationship {
		case is ToOneRelationship:
				payload = try! toOnePayload(resource.valueForField(relationship.name) as? Resource)
		case is ToManyRelationship:
			let relatedResources = (resource.valueForField(relationship.name) as? ResourceCollection)?.resources ?? []
			payload = try! toManyPayload(relatedResources)
		default:
			assertionFailure("Cannot only replace relationship contents for ToOneRelationship and ToManyRelationship")
			return
		}

		Spine.logInfo(.Spine, "Replacing relationship \(relationship) using URL: \(URL)")
		networkClient.request("PATCH", URL: URL, payload: payload, callback: handleNetworkResponse)
	}
}

/// A RelationshipMutateOperation mutates a to-many relationship by adding or removing linked resources.
private class RelationshipMutateOperation: RelationshipOperation {
	enum Mutation {
		case Add, Remove
	}
	
	let resource: Resource
	let relationship: ToManyRelationship
	let mutation: Mutation

	init(resource: Resource, relationship: ToManyRelationship, mutation: Mutation, spine: Spine) {
		self.resource = resource
		self.relationship = relationship
		self.mutation = mutation
		super.init()
		self.spine = spine
	}

	override func execute() {
		let resourceCollection = resource.valueForField(relationship.name) as! LinkedResourceCollection
		let httpMethod: String
		let relatedResources: [Resource]
		
		switch mutation {
		case .Add:
			httpMethod = "POST"
			relatedResources = resourceCollection.addedResources
		case .Remove:
			httpMethod = "DELETE"
			relatedResources = resourceCollection.removedResources
		}
		
		guard !relatedResources.isEmpty else {
			self.result = Failable()
			self.state = .Finished
			return
		}
		
		let URL = router.URLForRelationship(relationship, ofResource: resource)
		let payload = try! toManyPayload(relatedResources)
		Spine.logInfo(.Spine, "Mutating relationship \(relationship) using URL: \(URL)")
		networkClient.request(httpMethod, URL: URL, payload: payload, callback: handleNetworkResponse)
	}
}
