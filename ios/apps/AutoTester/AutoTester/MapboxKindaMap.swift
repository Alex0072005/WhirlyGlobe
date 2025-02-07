//
//  MapboxKindaMap.swift
//  WhirlyGlobeMaplyComponent
//
//  Created by Steve Gifford on 11/11/19.
//  Copyright © 2019 mousebird consulting. All rights reserved.
//

import UIKit
import WhirlyGlobeMaplyComponent

/**
    Convenience class for loading a Mapbox-style vector tiles-probably kinda map.
    You give it a style sheet and it figures out the rest.
    Set the various settings before it gets going to modify how it works.
    Callbacks control various pieces that might need to be intercepted.
 */
public class MapboxKindaMap {
    public var styleURL: URL? = nil
    public weak var viewC : MaplyBaseViewController? = nil

    // If set, we build an image/vector hybrid where the polygons go into
    //  the image layer and the linears and points are represented as vectors
    // Otherwise, it's all put in a PagingLayer as vectors.  This is better for an overlay.
    public var imageVectorHybrid = true
    
    // If set, we'll sort all polygons into the background
    // Works well zoomed out, less enticing zoomed in
    public var backgroundAllPolys = true
    
    // If set, a top level directory where we'll cache everything
    public var cacheDir : URL? = nil

    // If set, you can override the file loaded for a particular purpose.
    // This includes: the TileJSON files, sprite sheets, and the style sheet itself
    // For example, if you want to load from the bundle, but not have to change
    //  anything in the style sheet, just do this
    public var fileOverride : (_ file: URL) -> URL = { return $0 }
    
    // If set, we'll consult this on the font to use for a given
    //  font name in the style.  Font names in the style often don't map
    //  directly to local font names.
    public var fontOverride : (_ name: String) -> UIFontDescriptor? = { _ in return nil }
    
    public init() {
    }
    
    public init(_ styleURL: URL, viewC: MaplyBaseViewController) {
        self.viewC = viewC
        self.styleURL = styleURL
    }
    
    public var styleSettings = MaplyVectorStyleSettings()
    public var styleSheet : MapboxVectorStyleSet? = nil
    public var styleSheetImage : MapboxVectorStyleSet? = nil
    public var styleSheetVector : MapboxVectorStyleSet? = nil
    public var styleSheetData : Data? = nil
    public var spriteJSON : Data? = nil
    public var spritePNG : UIImage? = nil
    
    // Information about the sources as we fetch them
    public var outstandingFetches : [URLSessionDataTask?] = []
    
    // Check if we've finished loading stuff
    private func checkFinished() {
        DispatchQueue.main.async {
            var done = true
            
            // If any of the oustanding fetches are running, don't start
            self.outstandingFetches.forEach {
                if $0?.state == .running {
                    done = false
                }
            }
            
            // All done, so start
            if done {
                self.startLoader()
            }
        }
    }
    
    public var pageLayer : MaplyQuadPagingLayer? = nil
    public var pageDelegate : MapboxVectorTilesPagingDelegate? = nil
    public var mapboxInterp : MapboxVectorImageInterpreter? = nil
    public var loader : MaplyQuadImageLoader? = nil
    public var offlineRender : MaplyRenderController? = nil
    
    // If we're using a cache dir, look for the file there
    private func cacheResolve(_ url: URL) -> URL {
        let fileName = cacheName(url)
        if !fileName.isFileURL || !FileManager.default.fileExists(atPath: fileName.path) {
            return url
        }
        
        return fileName
    }
    
    // Generate a workable cache file path
    private func cacheName(_ url: URL) -> URL {
        guard let cacheDir = cacheDir else {
            return url
        }
        
        // Make sure the cache dir exists
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        // It's already local
        if url.isFileURL {
            return url
        }
        
        // Make up a cache name from the URL
        let cacheName = url.absoluteString.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let fileURL = cacheDir.appendingPathComponent(cacheName)
        
        return fileURL
    }
    
    // Write a file to cache if appropriate
    private func cacheFile(_ url: URL, data: Data) {
        // If there's no cache dir or the file is local, don't cache
        if cacheDir == nil || url.isFileURL {
            return
        }
        
        let theCacheName = cacheName(url)
        try? data.write(to: theCacheName)
    }
    
    // Done messing with settings?  Then fire this puppy up
    // Will shut down the loader(s) it started
    public func start() {
        guard let viewC = viewC,
            var styleURL = styleURL else {
            return
        }

        // Dev might be overriding the source
        styleURL = fileOverride(styleURL)
        styleURL = cacheResolve(styleURL)
        
        // Go get the style sheet (this will also handle local
        let dataTask = URLSession.shared.dataTask(with: styleURL) {
            (data, resp, error) in
            guard error == nil, let data = data else {
                print("Error fetching style sheet:\n\(String(describing: error))")
                
                self.stop()
                return
            }
            
            DispatchQueue.main.async {
                guard let styleSheet = MapboxVectorStyleSet(json: data,
                                                      settings: self.styleSettings,
                                                        viewC: viewC,
                                                        filter: nil) else {
                    print("Failed to parse style sheet")
                    return
                }
                self.styleSheetData = data
                self.styleSheet = styleSheet
                self.cacheFile(self.styleURL!, data: data)
                
                // Fetch what we need to for the sources
                var success = true
                styleSheet.sources.forEach {
                    let source = $0 as! MaplyMapboxVectorStyleSource
                    if source.tileSpec == nil && success {
                        guard let urlStr = source.url,
                            let origURL = URL(string: urlStr) else {
                            print("Expecting either URL or tile info for a source.  Giving up.")
                            success = false
                            return
                        }
                        let url = self.cacheResolve(self.fileOverride(origURL))
                        
                        // Go fetch the TileJSON
                        let dataTask = URLSession.shared.dataTask(with: url) {
                            (data, resp, error) in
                            guard error == nil else {
                                print("Error trying to fetch tileJson from \(urlStr)")
                                self.stop()
                                return
                            }
                            
                            DispatchQueue.main.async {
                                if let data = data,
                                    let resp = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                                    source.tileSpec = resp
                                    
                                    self.cacheFile(origURL, data: data)

                                    self.checkFinished()
                                }
                            }
                        }
                        self.outstandingFetches.append(dataTask)
                        dataTask.resume()
                    }
                }
                
                // And for the sprite sheets
                if let spriteURLStr = styleSheet.spriteURL,
                    let spriteJSONurl = URL(string: spriteURLStr)?.appendingPathComponent("sprite@2x.json"),
                    let spritePNGurl = URL(string: spriteURLStr)?.appendingPathComponent("sprite@2x.png") {
                        let dataTask1 = URLSession.shared.dataTask(with: self.cacheResolve(self.fileOverride(spriteJSONurl))) {
                            (data, resp, error) in
                            guard error == nil else {
                                print("Failed to fetch spriteJSON from \(spriteURLStr)")
                                self.stop()
                                return
                            }
                            
                            DispatchQueue.main.async {
                                if let data = data {
                                    self.spriteJSON = data

                                    self.cacheFile(spriteJSONurl, data: data)
                                }

                                self.checkFinished()
                            }
                        }
                        self.outstandingFetches.append(dataTask1)
                        dataTask1.resume()
                        let dataTask2 = URLSession.shared.dataTask(with: self.cacheResolve(self.fileOverride(spritePNGurl))) {
                            (data, resp, error) in
                            guard error == nil else {
                                print("Failed to fetch spritePNG from \(spriteURLStr)")
                                self.stop()
                                return
                            }
                            DispatchQueue.main.async {
                                if let data = data {
                                    self.spritePNG = UIImage(data: data)
                                    
                                    self.cacheFile(spritePNGurl, data: data)
                                }
                                
                                self.checkFinished()
                            }
                        }
                        self.outstandingFetches.append(dataTask2)
                        dataTask2.resume()
                    }
                
                if !success {
                    self.stop()
                }
            }
        }
        outstandingFetches.append(dataTask)
        dataTask.resume()
    }
    
    // Everything has been fetched, so fire up the loader
    private func startLoader() {
        guard let styleSheet = styleSheet,
            let viewC = viewC else {
            return
        }

        // Figure out overall min/max zoom
        var zoom : (min: Int32, max: Int32) = (10000, -1)
        styleSheet.sources.forEach {
            guard let source = $0 as? MaplyMapboxVectorStyleSource else {
                print("Bad format in tileInfo for style sheet")
                return
            }
            if let minZoom = source.tileSpec?["minzoom"] as? Int32,
                let maxZoom = source.tileSpec?["maxzoom"] as? Int32 {
                zoom.min = min(minZoom,zoom.min)
                zoom.max = max(maxZoom,zoom.max)
            }
        }

        // Image/vector hybrids draw the polygons into a background image
        if imageVectorHybrid {
            // Put together the tileInfoNew objects
            var tileInfos : [MaplyRemoteTileInfoNew] = []
            styleSheet.sources.forEach {
                guard let source = $0 as? MaplyMapboxVectorStyleSource else {
                    print("Bad format in tileInfo for style sheet")
                    return
                }
                if let minZoom = source.tileSpec?["minzoom"] as? Int32,
                    let maxZoom = source.tileSpec?["maxzoom"] as? Int32,
                    let tiles = source.tileSpec?["tiles"] as? [String] {
                    let tileSource = MaplyRemoteTileInfoNew(baseURL: tiles[0], minZoom: minZoom, maxZoom: maxZoom)
                    tileInfos.append(tileSource)
                }
            }
            
            // Parameters describing how we want a globe broken down
            let sampleParams = MaplySamplingParams()
            sampleParams.coordSys = MaplySphericalMercator(webStandard: ())
            sampleParams.minImportance = 1024 * 1024
            sampleParams.singleLevel = true
            if viewC is WhirlyGlobeViewController {
                sampleParams.coverPoles = true
                sampleParams.edgeMatching = true
            } else {
                sampleParams.coverPoles = false
                sampleParams.edgeMatching = false
            }
            sampleParams.minZoom = zoom.min
            sampleParams.maxZoom = zoom.max

            // TODO: Handle more than one source
            guard let imageLoader = MaplyQuadImageLoader(params: sampleParams, tileInfos: tileInfos, viewC: viewC) else {
//            guard let imageLoader = MaplyQuadImageLoader(params: sampleParams, tileInfo: tileInfos[0], viewC: viewC) else {
                print("Failed to start image loader.  Nothing will appear.")
                self.stop()
                return
            }
            loader = imageLoader
            
            guard let styleSheetData = styleSheetData else {
                return
            }
                        
            if self.backgroundAllPolys {
                // Set up an offline renderer and a Mapbox vector style handler to render to it
                let imageSize = (width: 512.0, height: 512.0)
                guard let offlineRender = MaplyRenderController.init(size: CGSize.init(width: imageSize.width, height: imageSize.height)) else {
                    print("Failed to start offline renderer.  Nothing will appear.")
                    self.stop()
                    return
                }
                self.offlineRender = offlineRender
                let imageStyleSettings = MaplyVectorStyleSettings.init(scale: UIScreen.main.scale)
                imageStyleSettings.arealShaderName = kMaplyShaderDefaultTriNoLighting

                // We only want the polygons in the image
                guard let styleSheetImage = MapboxVectorStyleSet.init(json: styleSheetData,
                                                                    settings: imageStyleSettings,
                                                                    viewC: offlineRender,
                                                                    filter:
                    { (styleAttrs) -> Bool in
                        // We only want polygons for the image
                        if let type = styleAttrs["type"] as? String {
                            if type == "background" || type == "fill" {
                                return true
                            }
                        }
                        return false
                }) else {
                        print("Failed to set up image style sheet.  Nothing will appear.")
                        self.stop()
                        return
                }
                self.styleSheetImage = styleSheetImage
            }
            
            // Just the linear and point vectors in the overlay
            styleSettings.baseDrawPriority = 100+1
            styleSettings.drawPriorityPerLevel = 1000
            guard let styleSheetVector = MapboxVectorStyleSet.init(json: styleSheetData,
                                                                 settings: styleSettings,
                                                                 viewC: viewC,
                                                                 filter:
                { (styleAttrs) -> Bool in
                    if self.backgroundAllPolys {
                        // We want everything but the polygons
                        if let type = styleAttrs["type"] as? String {
                            if type != "background" && type != "fill" {
                                return true
                            }
                        }
                        return false
                    } else {
                        // That mode's not on, so leave it alone
                        return true
                    }
            })
                else {
                    print("Failed to set up vector style sheet.  Nothing will appear.")
                    self.stop()
                    return
            }
            self.styleSheetVector = styleSheetVector

            if let offlineRender = offlineRender,
                let styleSheetImage = styleSheetImage {
                // The interpreter does the work off offline render and conversion to WG-Maply objects
                guard let mapboxInterp = MapboxVectorImageInterpreter(loader: imageLoader,
                                                                      imageStyle: styleSheetImage,
                                                                      offlineRender: offlineRender,
                                                                      vectorStyle: styleSheetVector,
                                                                      viewC: viewC) else {
                     print("Failed to set up Mapbox interpreter.  Nothing will appear.")
                     self.stop()
                     return
                }
                self.mapboxInterp = mapboxInterp
            } else {
                // The interpreter does the work off offline render and conversion to WG-Maply objects
                guard let mapboxInterp = MapboxVectorImageInterpreter(loader: imageLoader,
                                                                      style: styleSheetVector,
                                                                      viewC: viewC) else {
                     print("Failed to set up Mapbox interpreter.  Nothing will appear.")
                     self.stop()
                     return
                }
                self.mapboxInterp = mapboxInterp
            }
            imageLoader.setInterpreter(self.mapboxInterp!)
            
        } else {
            // Assemble the tile sources
            var tileSources : [MaplyRemoteTileInfo] = []
            styleSheet.sources.forEach {
                guard let source = $0 as? MaplyMapboxVectorStyleSource else {
                    print("Bad format in tileInfo for style sheet")
                    return
                }
                if let minZoom = source.tileSpec?["minzoom"] as? Int32,
                    let maxZoom = source.tileSpec?["maxzoom"] as? Int32,
                    let tiles = source.tileSpec?["tiles"] as? [String] {
                    let tileSource = MaplyRemoteTileInfo(baseURL: tiles[0], ext: nil, minZoom: minZoom, maxZoom: maxZoom)
                    tileSources.append(tileSource)
                }
            }

            // One tile source per tile spec
            // TODO: Hook up multiple paging layers
            let tileSource = MaplyRemoteTileSource(info: tileSources[0])!
            let pageDelegate = MapboxVectorTilesPagingDelegate(tileSource: tileSource, style: styleSheet, viewC: viewC)
            //            pageDelegate.tileParser?.debugLabel = true
            //            pageDelegate.tileParser?.debugOutline = true
            if let pageLayer = MaplyQuadPagingLayer(coordSystem: MaplySphericalMercator(), delegate: pageDelegate) {
                pageLayer.flipY = false
                pageLayer.importance = 512*512;
                pageLayer.singleLevelLoading = true
                
                // Background layer supplies the background color
                if let backLayer = styleSheet.layersByName!["background"] as? MapboxVectorLayerBackground? {
                    viewC.clearColor = backLayer?.paint.color
                }
                self.pageLayer = pageLayer
                viewC.add(pageLayer)
            }
            self.pageDelegate = pageDelegate
        }
    }
    
    public func stop() {
        // If we're still fetching config data, cancel that
        outstandingFetches.forEach {
            $0?.cancel()
        }
        outstandingFetches = []

        if let pageLayer = pageLayer {
            viewC?.remove(pageLayer)
        }
        pageLayer = nil
        pageDelegate = nil
        loader?.shutdown()
        loader = nil
        mapboxInterp = nil
    }
}
