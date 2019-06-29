//
// Jukebox.swift
//
// Copyright (c) 2015 Teodor Patraş
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import AVFoundation
import MediaPlayer

// MARK: - Custom types -

public protocol JukeboxDelegate: class {
    func jukeboxStateDidChange(_ jukebox : Jukebox)
    func jukeboxPlaybackProgressDidChange(_ jukebox : Jukebox)
    func jukeboxDidLoadItem(_ jukebox : Jukebox, item : JukeboxItem)
    func jukeboxDidUpdateMetadata(_ jukebox : Jukebox, forItem: JukeboxItem)
    func jukeboxDidBeginInterruption(_ jukebox: Jukebox)
    func jukeboxDidEndInterruption(_ jukebox: Jukebox)
    func jukeboxAutoplayNext(_ jukebox:Jukebox, fromItem: JukeboxItem?, toItem: JukeboxItem?)
    func jukeboxDidStartNewPlayer(_ jukebox: Jukebox)
}

// MARK: - Public methods extension -

extension Jukebox {
    
    /**
     Starts item playback.
     */
    public func play() {
        play(atIndex: playIndex)
    }
    
    /**
     Plays the item indicated by the passed index
     
     - parameter index: index of the item to be played
     */
    func play(atIndex index: Int) {
        guard index < queuedItems.count && index >= 0 else {return}
        
        configureBackgroundAudioTask()
        
        let trackNumber = self.trackNumber(at: index)
        
        guard queuedItems.indices.contains(trackNumber) else {
            self.updateInfoCenter()
            return
        }
        
        if queuedItems[trackNumber].playerItem != nil && self.trackNumber() == trackNumber {
            if let playItem = queuedItems[trackNumber].playerItem {
                registerForPlayToEndNotification(withItem: playItem)
            }
            resumePlayback()
        } else {
            if let item = currentItem?.playerItem {
                unregisterForPlayToEndNotification(withItem: item)
            }
            
            playIndex = index
            
            if let asset = queuedItems[trackNumber].playerItem?.asset {
                playCurrentItem(withAsset: asset)
            } else {
                loadPlaybackItem()
            }
            
            preloadNextAndPrevious(atIndex: playIndex)
        }
        updateInfoCenter()
    }
    
    /**
     Plays the item from the queue indicated by the passed track number.
     - parameters 
        - trackNumber: track number of the item to be played.
     */
    public func play(trackNumber: Int) {
        
        var index = trackNumber
        
        if self.isShuffled {
            if let num = self.shuffleIndex.index(of: trackNumber) {
                
                if num != 0 && self.queuedItems.count > 1 {
                    let item = self.shuffleIndex.remove(at: num)
                    self.shuffleIndex.insert(item, at: 0)
                    index = 0
                    self.playIndex = 1
                }
            }
        }
        
        self.play(atIndex: index)
    }
    
    /**
     Pauses the playback.
     */
    public func pause() {
        stopProgressTimer()
        player?.pause()
        state = .paused
        self.updateInfoCenter()
    }
    
    /**
     Stops the playback.
     */
    public func stop() {
        invalidatePlayback()
        state = .ready
        UIApplication.shared.endBackgroundTask(backgroundIdentifier)
        backgroundIdentifier = UIBackgroundTaskIdentifier.invalid
        
        if self.queuedItems.count > 0 {
            self.shuffleIndex = Array(0..<self.queuedItems.count)
            self.shuffleTrackNumber()
        } else {
            self.shuffleIndex = []
        }
        
        self.updateInfoCenter()
    }
    
    /**
     Starts playback from the beginning of the queue.
     */
    public func replay(){
        guard playerOperational else {return}
        stopProgressTimer()
        seek(toSecond: 0)
        play(atIndex: 0)
    }
    
    /**
     Plays the next item in the queue.
     */
    public func playNext() {
        guard playerOperational else {return}
        switch self.repeatMode {
        case .off, .repeatOne:
            if playIndex >= queuedItems.count - 1 {
                self.stop()
            } else {
                self.play(atIndex: playIndex + 1)
            }
        case .repeatAll:
            let nextIndex = (self.playIndex + 1) % self.queuedItems.count
            self.play(atIndex: nextIndex)
        }
    }
    
    /**
     Restarts the current item or plays the previous item in the queue
     */
    public func playPrevious() {
        guard playerOperational else {return}
        
        switch self.repeatMode {
        case .off, .repeatOne:
            if playIndex <= 0 {
                self.stop()
            } else {
                self.play(atIndex: playIndex - 1)
            }
        case .repeatAll:
            
            let count = self.queuedItems.count
            
            guard count > 0 else {
                self.stop()
                return
            }
            
            let preIndex = (self.playIndex - 1 + count) % self.queuedItems.count
            self.play(atIndex: preIndex)
        }
        
    }
    
    /**
     Restarts the playback for the current item.
     
     - parameters:
        - fromStart: If true, start playing from 0. Otherwise, start from `startTime`
     */
    public func replayCurrentItem(fromStart: Bool) {
        guard playerOperational else {return}
        
        var sec = self.currentItem?.startTime ?? 0
        
        if fromStart {
            sec = 0
        }
        
        seek(toSecond: sec, shouldPlay: true)
    }
    
    /**
     Seeks to a certain second within the current AVPlayerItem and starts playing
     
     - parameter second: the second to seek to
     - parameter shouldPlay: pass true if playback should be resumed after seeking
     */
    public func seek(toSecond second: Double, shouldPlay: Bool = false) {
        guard let player = player, let item = currentItem else {return}
        
        var second = max(0, second)
        
        if let duration = item.meta.duration {
            
            let secInDouble = Double(second)
            
            if secInDouble > duration {
                second = 0
            }
        }
        
        
        player.seek(to:  CMTime(seconds: second, preferredTimescale: 1))
        item.update()
        if shouldPlay {
            player.play()
            if state != .playing {
                state = .playing
            }
        }
        delegate?.jukeboxPlaybackProgressDidChange(self)
    }
    
    /**
     Seeks to a certain progress(from 0.0 to 1.0) within the current AVPlayerItem and starts playing
     
     - parameter progress: the progress to seek to
     - parameter shouldPlay: pass true if playback should be resumed after seeking
     */
    public func seek(toProgress value: Float, shouldPlay: Bool = false) {
        guard let item = currentItem else {return}
        
        if let duration = item.meta.duration {
            if duration > 0 {
                let second = Double(value) * duration
                self.seek(toSecond: second, shouldPlay: shouldPlay)
            }
        }
    }
    
    /**
     Appends and optionally loads an item
     
     - parameter item:            the item to be appended to the play queue
     - parameter loadingAssets:   pass true to load item's assets asynchronously
     */
    public func append(item: JukeboxItem, loadingAssets: Bool) {
        
        if self.shuffleIndex != nil {
            self.shuffleIndex.append(queuedItems.count)
        }
        
        queuedItems.append(item)
        item.delegate = self
        
        if loadingAssets {
            item.loadPlayerItem()
        }
    }

    /**
    Removes an item from the play queue
    
    - parameter item: item to be removed
    */
    public func remove(item: JukeboxItem) {
        if let trackNumber = queuedItems.index(where: {$0.identifier == item.identifier}) {
            
            var item: JukeboxItem?
            
            if trackNumber == self.trackNumber() {
                self.stop()
            } else {
                item = self.currentItem
            }
            
            if !self.isShuffled {
                if trackNumber < self.playIndex {
                    self.playIndex -= 1
                }
            }
            
            queuedItems.remove(at: trackNumber)
            
            if self.isShuffled {
                if self.queuedItems.count > 0 {
                    self.shuffleIndex = Array(0..<self.queuedItems.count - 1)
                    self.shuffleTrackNumber()
                    
                    if item != nil {
                        if let trackNum = self.queuedItems.index(of: item!) {
                            if let playIndexNum = self.shuffleIndex.index(of: trackNum) {
                                let tmp = self.shuffleIndex.remove(at: playIndexNum)
                                self.shuffleIndex.insert(tmp, at: 0)
                                self.playIndex = 0
                            }
                        }
                    }
                } else {
                    self.shuffleIndex = []
                }
            }
        }
    }
    
    /**
     Removes all items from the play queue matching the URL
     
     - parameter url: the item URL
     */
    public func removeItems(withURL url : URL) {
        let indexes = queuedItems.indexesOf({$0.URL as URL == url})
        for index in indexes {
            queuedItems.remove(at: index)
        }
    }
    
    public func rearrangeItem(from: Int, to: Int) {
        
        if from == to {
            return
        }
        
        guard self.queuedItems.indices.contains(from) else {
            return
        }
        
        guard self.queuedItems.indices.contains(to) else {
            return
        }
        
        let item = self.queuedItems.remove(at: from)
        
        self.queuedItems.insert(item, at: to)
        
        // update playIndex if in a non-shuffle mode.
        if !self.isShuffled {
            if self.playIndex == from {
                self.playIndex = to
            } else if (from < playIndex && to < playIndex) || (from > playIndex && to > playIndex) {
                // no need to update from movement involved only under/above current item
            } else {
                if from < self.playIndex {
                    self.playIndex -= 1
                } else {
                    self.playIndex += 1
                }
            }
        }
    }
}


// MARK: - Class implementation -

open class Jukebox: NSObject, JukeboxItemDelegate {
    
    public enum State: Int, CustomStringConvertible {
        case ready = 0
        case playing
        case paused
        case loading
        case failed
        
        public var description: String {
            get{
                switch self
                {
                case .ready:
                    return "Ready"
                case .playing:
                    return "Playing"
                case .failed:
                    return "Failed"
                case .paused:
                    return "Paused"
                case .loading:
                    return "Loading"
                    
                }
            }
        }
    }
    
    public enum RepeatMode: Int, CustomStringConvertible {
        case off = 0
        case repeatOne = 1
        case repeatAll = 2
        
        public var description: String {
            get{
                switch self
                {
                case .off:
                    return "off"
                case .repeatOne:
                    return "repeatOne"
                case .repeatAll:
                    return "repeatAll"
                }
            }
        }
    }
    
    // MARK:- Properties
    
    public var isShuffled: Bool = false {
        
        willSet {
            
            let shuffled = newValue
            
            if self.isShuffled == shuffled {
                return
            }
            
            if !shuffled {
                if self.currentItem?.playerItem != nil {
                    if self.queuedItems.count > 0 && self.shuffleIndex != nil {
                        self.playIndex = self.shuffleIndex[self.playIndex]
                    }
                }
            } else {
                if self.shuffleIndex == nil {
                    
                    if self.queuedItems.isEmpty {
                        self.shuffleIndex = []
                    } else {
                        self.shuffleIndex = Array(0..<self.queuedItems.count)
                    }
                }
                self.shuffleTrackNumber()
                
                if self.currentItem?.playerItem != nil {
                    if let num = self.shuffleIndex.index(of: self.playIndex) {
                        
                        let item = self.shuffleIndex.remove(at: num)
                        self.shuffleIndex.insert(item, at: 0)
                        self.playIndex = 0
                    }
                }
            }
        }
        
        didSet {
            if self.isShuffled != oldValue {
                self.preloadNextAndPrevious(atIndex: self.playIndex)
            }
        }
    }
    
    fileprivate var shuffleIndex: [Int]!
    
    fileprivate var player                       :   AVPlayer?
    fileprivate var progressObserver             :   AnyObject!
    fileprivate var backgroundIdentifier         =   UIBackgroundTaskIdentifier.invalid
    fileprivate(set) open weak var delegate    :   JukeboxDelegate?
    
    fileprivate (set) open var playIndex       =   0
    fileprivate (set) open var queuedItems     :   [JukeboxItem]!
    fileprivate (set) open var state           =   State.ready {
        didSet {
            delegate?.jukeboxStateDidChange(self)
        }
    }
    
    public var repeatMode: RepeatMode = .off
    
    // MARK:  Computed
    
    open var volume: Float = 0.5 {
        didSet {
            self.player?.volume = self.volume
        }
    }
    
    open var currentItem: JukeboxItem? {
        
        let trackNumber = self.trackNumber()
        
        guard self.queuedItems.indices.contains(trackNumber) else {
            return nil
        }
        
        return queuedItems[trackNumber]
    }
    
    fileprivate var playerOperational: Bool {
        return player != nil && currentItem != nil
    }
    
    // MARK:- Initializer -
    
    /**
    Create an instance with a delegate and a list of items without loading their assets.
    
    - parameter delegate: jukebox delegate
    - parameter items:    array of items to be added to the play queue
    - parameter nowPlayingSetup: listen to Now Playing Center commands, if true. Otherwise, false.
    - returns: Jukebox instance
    */
    public required init?(delegate: JukeboxDelegate? = nil, items: [JukeboxItem] = [JukeboxItem](), nowPlayingSetup: Bool = false)  {
        self.delegate = delegate
        super.init()
        
        do {
            try configureAudioSession()
        } catch {
            print("[Jukebox - Error] \(error)")
            return nil
        }
        
        assignQueuedItems(items)
        configureObservers()
        
        if nowPlayingSetup {
            self.setupNowPlayingInfoCenter()
        }
    }
    
    deinit{
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Utilities
    
    /**
     Get the item of the given identifier, if Jukebox has it.
     
     - parameters:
        - identifier: id of the item.
     - returns: nil, if no such item in the queue. Otherwise, return the wanted item.
     */
    public func item(ofIdentifier identifier: String) -> JukeboxItem? {
        if let num = self.queuedItems.index(where: {$0.identifier == identifier}) {
            return self.queuedItems[num]
        }
        
        return nil
    }
    
    /**
     Return the track number with an assoicated playIndex. Track number is the index number of the queue items. When shuffle mode is off, this returns the `self.playIndex`. Otherwise, pre-generated track number, that is associated with the `index`, is returned.
     - parameters:
        - index: an optional associated integer for getting the track number. `self.playIndex` is used, if it's nil.
     - returns: a track number.
     */
    public func trackNumber(at index: Int? = nil) -> Int {
        
        let index = index ?? self.playIndex
        
        guard self.queuedItems.indices.contains(index) else {
            print("invalid index : \(index)")
            return -1
        }
        
        if self.isShuffled && self.shuffleIndex != nil {
            
            guard self.shuffleIndex.indices.contains(index) else {
                print("invalid index : \(index)")
                return -1
            }
            
            let result = self.shuffleIndex[index]
            
            if self.queuedItems.indices.contains(result) {
                return result
            } else {
                return Int(arc4random_uniform(UInt32(self.queuedItems.count)))
            }
        } else {
            return index
        }
    }
    
    func shuffleTrackNumber() {
        
        guard self.shuffleIndex != nil else {
            return
        }
        
        let c = self.shuffleIndex.count
        
        guard c > 1 else { return }
        
        for (firstUnshuffled, unshuffledCount) in zip(self.shuffleIndex.indices, stride(from: c, to: 1, by: -1)) {
            // Change `Int` in the next line to `IndexDistance` in < Swift 4.1
            let d: Int = numericCast(arc4random_uniform(numericCast(unshuffledCount)))
            let i = self.shuffleIndex.index(firstUnshuffled, offsetBy: d)
            self.shuffleIndex.swapAt(firstUnshuffled, i)
        }
    }
    
    // MARK:- JukeboxItemDelegate -
    
    func jukeboxItemDidFail(_ item: JukeboxItem) {
        stop()
        state = .failed
    }
    
    func jukeboxItemDidUpdate(_ item: JukeboxItem) {
        guard let item = currentItem else {return}
        updateInfoCenter()
        self.delegate?.jukeboxDidUpdateMetadata(self, forItem: item)
    }
    
    func jukeboxItemDidLoadPlayerItem(_ item: JukeboxItem) {
        delegate?.jukeboxDidLoadItem(self, item: item)
        
        let trackNumber = queuedItems.index{$0 === item}
        
        guard let playItem = item.playerItem
            , state == .loading && self.trackNumber() == trackNumber else {return}
        
        registerForPlayToEndNotification(withItem: playItem)
        startNewPlayer(forItem: item)
    }
    
    // MARK:- Private methods -
    
    // MARK: Playback
    
    private func setupNowPlayingInfoCenter() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        
        MPRemoteCommandCenter.shared().playCommand.addTarget {
            event in
            
            self.play()
            return .success
        }
        
        MPRemoteCommandCenter.shared().pauseCommand.addTarget {
            event in
            
            self.pause()
            return .success
        }
        MPRemoteCommandCenter.shared().nextTrackCommand.addTarget {
            event in
            
            self.playNext()
            return .success
        }
        MPRemoteCommandCenter.shared().previousTrackCommand.addTarget {
            event in
            
            self.playPrevious()
            return .success
        }
        
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget {
            event in
            
            if self.state == .playing {
                self.pause()
            } else {
                self.play()
            }
            
            return .success
        }
    }
    
    public func updateInfoCenter() {
        guard let item = currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        let currentTime = item.currentTime ?? 0
        let duration = item.meta.duration ?? 0
        let trackNumber = playIndex
        let trackCount = queuedItems.count
        
        var title = item.meta.title
        var artist = item.meta.artist
        var album = item.meta.album
        var artwork = item.meta.artwork
        
        if let customMetaData = item.customMetaData {
            
            if let str = customMetaData["title"] as? String {
                title = str
            }
            
            if let str = customMetaData["artist"] as? String {
                artist = str
            }
            
            if let str = customMetaData["album"] as? String {
                album = str
            }
            
            if let img = customMetaData["artwork"] as? UIImage {
                artwork = img
            }
        }
        
        if let customTitle = item.customTitle, !customTitle.isEmpty {
            title = customTitle
        }
        
        var playbackRate = 0.0
        
        if self.state == .playing {
            playbackRate = 1.0
        }
        
        var nowPlayingInfo : [String : Any] = [
            MPMediaItemPropertyPlaybackDuration : duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime : currentTime,
            MPNowPlayingInfoPropertyPlaybackQueueCount :trackCount,
            MPNowPlayingInfoPropertyPlaybackQueueIndex : trackNumber,
            MPMediaItemPropertyMediaType : MPMediaType.anyAudio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate
        ]
        
        if title != nil {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }
        
        if artist != nil {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        }
        
        if album != nil {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        }
        
        if artwork != nil {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(image: artwork!)
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    fileprivate func playCurrentItem(withAsset asset: AVAsset) {
        
        let trackNumber = self.trackNumber()
        
        guard queuedItems.indices.contains(trackNumber) else {
            return
        }
        
        queuedItems[trackNumber].refreshPlayerItem(withAsset: asset)
        startNewPlayer(forItem: queuedItems[trackNumber])
        guard let playItem = queuedItems[trackNumber].playerItem else {return}
        registerForPlayToEndNotification(withItem: playItem)
    }
    
    fileprivate func resumePlayback() {
        if state != .playing {
            startProgressTimer()
            if let player = player {
                player.play()
            } else {
                currentItem!.refreshPlayerItem(withAsset: currentItem!.playerItem!.asset)
                startNewPlayer(forItem: currentItem!)
            }
            state = .playing
        }
    }
    
    fileprivate func invalidatePlayback(shouldResetIndex resetIndex: Bool = true) {
        stopProgressTimer()
        player?.pause()
        player = nil
        
        if resetIndex {
            playIndex = 0
        }
    }
    
    fileprivate func startNewPlayer(forItem jukeboxItem : JukeboxItem) {
        
        guard let item = jukeboxItem.playerItem else {
            return
        }
        
        invalidatePlayback(shouldResetIndex: false)
        player = AVPlayer(playerItem: item)
        
        self.volume = jukeboxItem.adjustedVolume
        
        player?.allowsExternalPlayback = false
        startProgressTimer()
        
        var startTime = jukeboxItem.continueTime ?? jukeboxItem.startTime
        jukeboxItem.continueTime = nil
        
        let duration = item.asset.duration.seconds
        
        // set start time to zero, if it is too close to end time.
        if duration < startTime + 1.5 {
            startTime = 0.0
        }
        
        seek(toSecond: startTime, shouldPlay: true)
        
        self.delegate?.jukeboxDidStartNewPlayer(self)
        
        updateInfoCenter()
    }
    
    // MARK: Items related
    
    fileprivate func assignQueuedItems (_ items: [JukeboxItem]) {
        queuedItems = items
        for item in queuedItems {
            item.delegate = self
        }
    }
    
    fileprivate func loadPlaybackItem() {
        guard playIndex >= 0 && playIndex < queuedItems.count else {
            return
        }
        
        stopProgressTimer()
        player?.pause()
        
        let trackNumber = self.trackNumber()
        
        guard queuedItems.indices.contains(trackNumber) else {
            return
        }
        
        queuedItems[trackNumber].loadPlayerItem()
        state = .loading
    }
    
    fileprivate func preloadNextAndPrevious(atIndex index: Int) {
        guard !queuedItems.isEmpty else {return}
        
        let count = queuedItems.count
        
        let pre = (index - 1 + count) % count
        let next = (index + 1) % count
        
        let preTrackNumber = self.trackNumber(at: pre)
        let nextTrackNumber = self.trackNumber(at: next)
        
        if queuedItems.indices.contains(preTrackNumber) {
            queuedItems[preTrackNumber].loadPlayerItem()
        }
        
        if queuedItems.indices.contains(nextTrackNumber) {
            queuedItems[nextTrackNumber].loadPlayerItem()
        }
    }
    
    // MARK: Progress tracking
    
    fileprivate func startProgressTimer(){
        guard let player = player , player.currentItem?.duration.isValid == true else {return}
        progressObserver = player.addPeriodicTimeObserver(forInterval: CMTimeMakeWithSeconds(0.05, preferredTimescale: Int32(NSEC_PER_SEC)), queue: nil, using: { [unowned self] (time : CMTime) -> Void in
            self.timerAction()
        }) as AnyObject
    }
    
    fileprivate func stopProgressTimer() {
        guard let player = player, let observer = progressObserver else {
            return
        }
        player.removeTimeObserver(observer)
        progressObserver = nil
    }
    
    // MARK: Configurations
    
    fileprivate func configureBackgroundAudioTask() {
        backgroundIdentifier =  UIApplication.shared.beginBackgroundTask (expirationHandler: { () -> Void in
            UIApplication.shared.endBackgroundTask(self.backgroundIdentifier)
            self.backgroundIdentifier = UIBackgroundTaskIdentifier.invalid
        })
    }
    
    fileprivate func configureAudioSession() throws {
        if #available(iOS 10.0, *) {
            try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback, mode: .default)
        } else {
            // Fallback on earlier versions
            AVAudioSession.sharedInstance().perform(NSSelectorFromString("setCategory:error:"), with: AVAudioSession.Category.playback)
            try AVAudioSession.sharedInstance().setMode(AVAudioSession.Mode.default)
        }
        try AVAudioSession.sharedInstance().setActive(true)
    }
    
    fileprivate func configureObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(Jukebox.handleStall), name: NSNotification.Name.AVPlayerItemPlaybackStalled, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
    }
    
    // MARK:- Notifications -
    
    @objc func handleAudioSessionInterruption(_ notification : Notification) {
        guard let userInfo = notification.userInfo as? [String: AnyObject] else { return }
        guard let rawInterruptionType = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber else { return }
        guard let interruptionType = AVAudioSession.InterruptionType(rawValue: rawInterruptionType.uintValue) else { return }

        switch interruptionType {
        case .began: //interruption started
            //self.pause()
            self.delegate?.jukeboxDidBeginInterruption(self)
        case .ended: //interruption ended
            if let rawInterruptionOption = userInfo[AVAudioSessionInterruptionOptionKey] as? NSNumber {
                let interruptionOption = AVAudioSession.InterruptionOptions(rawValue: rawInterruptionOption.uintValue)
                if interruptionOption == AVAudioSession.InterruptionOptions.shouldResume {
                    //self.resumePlayback()
                    self.delegate?.jukeboxDidEndInterruption(self)
                }
            }
        }
    }
    
    @objc func handleStall() {
        player?.pause()
        player?.play()
    }
    
    @objc func playerItemDidPlayToEnd(_ notification : Notification) {
        if self.repeatMode == .repeatOne {
            self.replayCurrentItem(fromStart: false)
        } else {
            let fromItem = self.currentItem
            self.playNext()
            
            let toItem = self.currentItem
            self.delegate?.jukeboxAutoplayNext(self, fromItem: fromItem, toItem: toItem)
        }
    }
    
    func timerAction() {
        guard player?.currentItem != nil else {return}
        currentItem?.update()
        guard currentItem?.currentTime != nil else {return}
        delegate?.jukeboxPlaybackProgressDidChange(self)
    }
    
    fileprivate func registerForPlayToEndNotification(withItem item: AVPlayerItem) {
        NotificationCenter.default.addObserver(self, selector: #selector(Jukebox.playerItemDidPlayToEnd(_:)), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: item)
    }
    
    fileprivate func unregisterForPlayToEndNotification(withItem item : AVPlayerItem) {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: item)
    }
}

private extension Collection {
    func indexesOf(_ predicate: (Iterator.Element) -> Bool) -> [Int] {
        var indexes = [Int]()
        for (index, item) in enumerated() {
            if predicate(item){
                indexes.append(index)
            }
        }
        return indexes
    }
}

private extension CMTime {
    var isValid : Bool { return (flags.intersection(.valid)) != [] }
}
