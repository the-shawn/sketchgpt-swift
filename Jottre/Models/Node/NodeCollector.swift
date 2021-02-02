//
//  NodeCollector.swift
//  Jottre
//
//  Created by Anton Lorani on 16.01.21.
//

import UIKit
import OSLog
import Foundation

protocol NodeCollectorObserver {
    func nodeCollectorDidChange()
}

class NodeCollector {
    
    // MARK: - Properties
    
    private var observers: [NodeCollectorObserver] = []
    
    private var observersEnabledValue: Bool = true
    
    private var backgroundFetchIsActiveValue: Bool = false
    
    var backgroundFetchIsActive: Bool {
        return backgroundFetchIsActiveValue
    }
    
    var observersEnabled: Bool {
        return observersEnabledValue
    }
    
    static func writePath() -> URL {
        return Settings.getLocalPath()
    }
    
    static func readPath() -> URL {
        return settings.getPath()
    }
    
    var nodes: [Node] = [] {
        didSet {
            didUpdate()
        }
    }
    
    var traitCollection: UITraitCollection = UITraitCollection() {
        didSet {
            update()
        }
    }
    
    
    
    // MARK: - Init
    
    /// Initializes the NodeCollector object and automatically pulls Nodes from the default container-path
    init() {
        pull()
        initializeBackgroundFetch(interval: 1)
    }
    
    

    // MARK: - Methods
    
    /// Loads the nodes from default path
    /// - Parameter completion: Returns a boolean that indicates success or failure
    func pull(completion: ((Bool) -> Void)? = nil) {
        nodes = []
        let files = try! FileManager.default.contentsOfDirectory(atPath: NodeCollector.readPath().path)
        files.forEach { (name) in
            let url = NodeCollector.readPath().appendingPathComponent(name)
            self.pullNode(url: url)
        }
        
        completion?(true)
    }
    
    
    /// Pulls a specific node from url.
    /// This node will be added to the NodeCollector
    /// - Parameters:
    ///   - url: Should point to a .jot file on the users file-system
    ///   - completion: Returns a boolean that indicates success or failure
    func pullNode(url: URL, completion: ((Bool) -> Void)? = nil) {

        let node = Node(url: url)
            node.collector = self
            node.pull { (success) in
                if success {
                    self.nodes.append(node)
                }
                completion?(success)
            }
        
    }
    
    
    /// Force pulls all the Nodes to the file-system
    /// - Parameter completion: Returns a boolean that indicates success or failure
    func push(completion: ((Bool) -> Void)? = nil) {
        
        nodes.forEach({ $0.push() })
        completion?(true)
        
    }
    
    
    /// Creates a new Node for given name
    /// - Parameter name: This will be the name and filename (without suffix .jot) of the Node
    /// - Parameter completion: Returns a boolean that indicates success or failure and the hopefully created node
    func createNode(name: String, completion: ((_ success: Bool, _ node: Node?) -> Void)? = nil) {
        
        let name = NodeCollector.computeCopyName(baseName: name, path: NodeCollector.writePath())
        let nodePath = NodeCollector.writePath().appendingPathComponent(name).appendingPathExtension("jot")
        
        let node = Node(url: nodePath)
            node.collector = self
            node.push { (success) in
                completion?(success, success ? node : nil)
            }
        
    }
    
    
    /// Updates the meta-data for each Node in this object
    func update() {
        nodes.forEach({ $0.updateMeta() })
    }
    
    
    /// Sends a message to each observer, that there happened changes inside this object.
    func didUpdate() {

        if !observersEnabled { return }
        
        DispatchQueue.main.async {
            self.observers.forEach({ $0.nodeCollectorDidChange() })
        }
        
    }
    
    
    
    // MARK: - Observer methods
    
    /// Enable observer calls ;)
    func enableObservers() {
        observersEnabledValue = true
    }
    
    
    /// Suppresses the observer calls ;)
    func disableObservers() {
        observersEnabledValue = false
    }
    
    
    /// Adds a new observer to this class ;)
    func addObserver(_ observer: NodeCollectorObserver) {
        observers.append(observer)
    }
    
    
    
    // MARK: - BackgroundFetch methods
    
    /// Activates Background fetches
    func startBackgroundFetch() {
        backgroundFetchIsActiveValue = true
    }
    
    
    /// Pauses the Background fetches (Process will be still running in the background)
    func pauseBackgroundFetch() {
        backgroundFetchIsActiveValue = false
    }
    
    
    /// Continuously fetches the newest version of the Node inside the NodeCollector
    /// - Parameter interval: Duration between each pull call
    private func initializeBackgroundFetch(interval: Int) {
        
        var isInitial: Bool = true
        
        DispatchQueue.main.async {
            
            Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { (timer) in
                
                if !self.backgroundFetchIsActive || isInitial {
                    isInitial = false
                    return
                }
                                
                let files = try! FileManager.default.contentsOfDirectory(atPath: NodeCollector.readPath().path)
                let fileURLs: [URL] = files.map({ NodeCollector.readPath().appendingPathComponent($0) })
                fileURLs.forEach { (url) in
                    
                    let tmpNode = Node(url: url)
                    tmpNode.pull { (success) in
                        if success {
                                                        
                            if let targetNode = self.nodes.filter({ $0.url == tmpNode.url! }).first {
                                
                                if Downloader.getStatus(url: targetNode.url!) == URLUbiquitousItemDownloadingStatus.current {
                                    targetNode.pullHandler(url: targetNode.url!) { (pullSuccess) in
                                        self.didUpdate()
                                    }
                                    return
                                }
                                                                
                                var finished: Bool = false
                                
                                let downloader = Downloader(url: targetNode.url!)
                                downloader.execute { (downloadSuccess) in
                                    finished = true
                                    if downloadSuccess {
                                        targetNode.pullHandler(url: targetNode.url!) { (pullSuccess) in
                                            self.didUpdate()
                                        }
                                    }
                                }
                                
                                while !finished {}
                                
                            } else {
                                self.nodes.append(tmpNode)
                            }
                            
                        }
                    }
                    
                }
                
                for node in self.nodes {
                    if !fileURLs.contains(node.url!) {
                        guard let index = self.nodes.firstIndex(of: node) else { continue }
                        self.nodes.remove(at: index)
                    }
                }

            }
            
        }
        
    }
    
    
    
    // MARK: - Static methods
    // FIXME: - This method is currently running on the main-thread. This needs to be changed.
    
    /// Generates a name and will modify it if this name already exists in a given directory
    /// - Complexity: O(n) where n is the number of files inside the root-folder
    /// - Parameter baseName: The target name
    /// - Parameter path: The path where this file is stored
    /// - Returns: The validated name (If name already exists this method adds the suffix ' copy' to the baseName)
    static func computeCopyName(baseName: String, path: URL) -> String {
        var newName: String = baseName
        var currentPath: URL = path.appendingPathComponent(newName).appendingPathExtension("jot")
        
        while true {
            if FileManager.default.fileExists(atPath: currentPath.path) {
                newName = "\(newName) " + NSLocalizedString("(copy)", comment: "")
                currentPath = currentPath.deletingLastPathComponent().appendingPathComponent(newName).appendingPathExtension("jot")
                continue
            }
            break
        }
        
        return newName
    }
    
}
