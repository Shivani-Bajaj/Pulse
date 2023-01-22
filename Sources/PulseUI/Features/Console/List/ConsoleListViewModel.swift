// The MIT License (MIT)
//
// Copyright (c) 2020–2023 Alexander Grebenyuk (github.com/kean).

import Foundation
import CoreData
import Pulse
import Combine
import SwiftUI

final class ConsoleListViewModel: NSObject, NSFetchedResultsControllerDelegate, ObservableObject {
    @Published private(set) var visibleEntities: ArraySlice<NSManagedObject> = []
    @Published private(set) var entities: [NSManagedObject] = []
    @Published private(set) var sections: [NSFetchedResultsSectionInfo]?
    @Published var options = ConsoleListOptions()

    let entitiesSubject = CurrentValueSubject<[NSManagedObject], Never>([])
    let didRefresh = PassthroughSubject<Void, Never>()

    var isViewVisible = false {
        didSet {
            if isViewVisible {
                reloadMessages(isMandatory: true)
            }
        }
    }

    @Published private(set) var mode: ConsoleMode = .all

    /// This exist strickly to workaround List performance issues
    private var scrollPosition: ScrollPosition = .nearTop
    private var visibleEntityCountLimit = fetchBatchSize
    private var visibleObjectIDs: Set<NSManagedObjectID> = []

    var grouping: ConsoleListGroupBy { mode == .tasks ? options.taskGroupBy : options.messageGroupBy }
    private let store: LoggerStore
    private let searchCriteriaViewModel: ConsoleSearchCriteriaViewModel
    private var controller: NSFetchedResultsController<NSManagedObject>?
    private var cancellables: [AnyCancellable] = []

    let logCountObserver: ManagedObjectsCountObserver
    let taskCountObserver: ManagedObjectsCountObserver

    init(store: LoggerStore, criteria: ConsoleSearchCriteriaViewModel) {
        self.store = store
        self.searchCriteriaViewModel = criteria

        self.logCountObserver = ManagedObjectsCountObserver(entity: LoggerMessageEntity.self, context: store.viewContext, sortDescriptior: NSSortDescriptor(key: "createdAt", ascending: false))
        self.taskCountObserver = ManagedObjectsCountObserver(entity: NetworkTaskEntity.self, context: store.viewContext, sortDescriptior: NSSortDescriptor(key: "createdAt", ascending: false))

        super.init()

        $entities.sink { [entitiesSubject] in
            entitiesSubject.send($0)
        }.store(in: &cancellables)

        searchCriteriaViewModel.$criteria
            .dropFirst()
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        searchCriteriaViewModel.$isOnlyErrors
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        searchCriteriaViewModel.$filterTerm
            .dropFirst()
            .throttle(for: 0.25, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        $options.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshController()
        }.store(in: &cancellables)

        refreshController()
    }

    func update(mode: ConsoleMode) {
        self.mode = mode
        self.refreshController()
    }

    // MARK: - NSFetchedResultsController

    func refreshController() {
        let request: NSFetchRequest<NSManagedObject>
        let sortKey = mode == .tasks ? options.taskSortBy.key : options.messageSortBy.key
        if mode == .tasks {
            request = .init(entityName: "\(NetworkTaskEntity.self)")
            request.sortDescriptors = [
                grouping.key.map { NSSortDescriptor(key: $0, ascending: grouping.isAscending) },
                NSSortDescriptor(key: sortKey, ascending: options.order == .ascending)
            ].compactMap { $0 }
        } else {
            request = .init(entityName: "\(LoggerMessageEntity.self)")
            request.relationshipKeyPathsForPrefetching = ["request"]
            request.sortDescriptors = [
                grouping.key.map { NSSortDescriptor(key: $0, ascending: grouping.isAscending) },
                NSSortDescriptor(key: sortKey, ascending: options.order == .ascending)
            ].compactMap { $0 }
        }
        request.fetchBatchSize = fetchBatchSize
        controller = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: store.viewContext,
            sectionNameKeyPath: grouping.key,
            cacheName: nil
        )
        controller?.delegate = self

        refresh()
    }

    func refresh() {
        guard let controller = controller else {
            return assertionFailure()
        }
        controller.fetchRequest.predicate = makePredicate(for: mode)
        try? controller.performFetch()

        logCountObserver.setPredicate(makePredicate(for: .logs))
        taskCountObserver.setPredicate(makePredicate(for: .tasks))

        reloadMessages()
        didRefresh.send(())
    }

    private func makePredicate(for mode: ConsoleMode) -> NSPredicate? {
        let criteria = searchCriteriaViewModel

        func makeMessagesPredicate(isMessageOnly: Bool) -> NSPredicate? {
            var predicates: [NSPredicate] = []
            if isMessageOnly {
                predicates.append(NSPredicate(format: "task == NULL"))
            }
            if let predicate = ConsoleSearchCriteria.makeMessagePredicates(criteria: criteria.criteria, isOnlyErrors: criteria.isOnlyErrors, filterTerm: criteria.filterTerm) {
                predicates.append(predicate)
            }
            return predicates.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        switch mode {
        case .all:
            return makeMessagesPredicate(isMessageOnly: false)
        case .logs:
            return makeMessagesPredicate(isMessageOnly: true)
        case .tasks:
            return ConsoleSearchCriteria.makeNetworkPredicates(criteria: criteria.criteria, isOnlyErrors: criteria.isOnlyErrors, filterTerm: criteria.filterTerm)
        }
    }

    // MARK: - NSFetchedResultsControllerDelegate

    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChangeContentWith diff: CollectionDifference<NSManagedObjectID>) {
        if isViewVisible {
            withAnimation {
                reloadMessages(isMandatory: false)
            }
        } else {
            entities = self.controller?.fetchedObjects ?? []
        }
    }

    private func reloadMessages(isMandatory: Bool = true) {
        entities = controller?.fetchedObjects ?? []
        sections = controller?.sectionNameKeyPath == nil ?  nil : controller?.sections
        if isMandatory || scrollPosition == .nearTop {
            refreshVisibleEntities()
        }
    }

    private func refreshVisibleEntities() {
        visibleEntities = entities.prefix(visibleEntityCountLimit)
    }

    // MARK: - Scroll Position

    private enum ScrollPosition {
        case nearTop
        case middle
        case nearBottom
    }

    func onDisappearCell(with objectID: NSManagedObjectID) {
        visibleObjectIDs.remove(objectID)
        refreshScrollPosition()
    }

    func onAppearCell(with objectID: NSManagedObjectID) {
        visibleObjectIDs.insert(objectID)
        refreshScrollPosition()
    }

    private func refreshScrollPosition() {
        let scrollPosition: ScrollPosition
        if visibleEntities.prefix(5).map(\.objectID).contains(where: visibleObjectIDs.contains) {
            scrollPosition = .nearTop
        } else if visibleEntities.suffix(5).map(\.objectID).contains(where: visibleObjectIDs.contains) {
            scrollPosition = .nearBottom
        } else {
            scrollPosition = .middle
        }

        if scrollPosition != self.scrollPosition {
            self.scrollPosition = scrollPosition
            switch scrollPosition {
            case .nearTop:
                visibleEntityCountLimit = fetchBatchSize // Reset
                refreshVisibleEntities()
            case .middle:
                break // Don't reload: too expensive and ruins gestures
            case .nearBottom:
                visibleEntityCountLimit += fetchBatchSize
                refreshVisibleEntities()
            }
        }
    }
}

private let fetchBatchSize = 100

enum ConsoleMode: String {
    case all
    case logs
    case tasks
}
