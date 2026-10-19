import Foundation
import Photos

struct PhotoTransferResource {
  let resource: PHAssetResource
  let filename: String
  let legacyFilename: String
  init(resource: PHAssetResource, filename: String, legacyFilename: String? = nil) {
    self.resource = resource
    self.filename = filename
    self.legacyFilename = legacyFilename ?? resource.originalFilename
  }
}

struct PhotoTransferPlan {
  let assetIdentifier: String
  let target: TargetSpace
  let creationDate: Date
  let type: SyncAssetType
  let resources: [PhotoTransferResource]

  init(asset: PHAsset, config: SyncConfig) throws {
    assetIdentifier = asset.localIdentifier
    creationDate = asset.creationDate ?? Date()
    target =
      config.targetSpace == .separate
      ? (asset.sourceType.contains(.typeCloudShared) ? .shared : .personal) : config.targetSpace
    let all = PHAssetResource.assetResources(for: asset)
    let video = asset.mediaType == .video
    let live = !video && asset.mediaSubtypes.contains(.photoLive) && config.saveLivePhotos
    type = live ? .livePhoto : (video ? .video : .photo)
    let original =
      video
      ? all.first { $0.type == .video } ?? all.first { $0.type == .fullSizeVideo }
      : all.first { $0.type == .photo } ?? all.first { $0.type == .alternatePhoto }
        ?? all.first { $0.type == .fullSizePhoto }
    guard let original else { throw PhotoTransferError.missingOriginal }
    let primaryName = FilenameSanitizer.assetFilename(
      original.originalFilename, identifier: asset.localIdentifier)
    var planned = [PhotoTransferResource(resource: original, filename: primaryName)]
    if live {
      guard
        let paired = all.first(where: { $0.type == .pairedVideo })
          ?? all.first(where: { $0.type == .fullSizePairedVideo })
      else { throw PhotoTransferError.missingLiveVideo }
      let ext = (FilenameSanitizer.sanitize(paired.originalFilename) as NSString).pathExtension
      let base = (primaryName as NSString).deletingPathExtension
      planned.append(
        PhotoTransferResource(resource: paired, filename: "\(base).\(ext.isEmpty ? "mov" : ext)"))
    }
    if config.saveEditedCopies {
      for source in Array(planned) {
        let editedType: PHAssetResourceType =
          (source.resource.type == .pairedVideo || source.resource.type == .fullSizePairedVideo)
          ? .fullSizePairedVideo : (video ? .fullSizeVideo : .fullSizePhoto)
        if let edited = all.first(where: { $0.type == editedType && $0 != source.resource }) {
          let base = (source.filename as NSString).deletingPathExtension
          let ext = (FilenameSanitizer.sanitize(edited.originalFilename) as NSString).pathExtension
          planned.append(
            PhotoTransferResource(
              resource: edited, filename: "\(base)_edited.\(ext)",
              legacyFilename:
                "\((source.legacyFilename as NSString).deletingPathExtension)_edited.\(ext)"))
        }
      }
    }
    resources = planned
  }
}

enum PhotoTransferError: LocalizedError {
  case missingOriginal, missingLiveVideo
  var errorDescription: String? {
    switch self {
    case .missingOriginal: return "PhotoKit не предоставил оригинальный ресурс."
    case .missingLiveVideo:
      return "В Live Photo отсутствует парное видео; объект не отмечен как синхронизированный."
    }
  }
}
