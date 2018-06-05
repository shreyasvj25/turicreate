#include "mps_networks.h"
#include "mps_layers.h"

MPSNetwork *_Nonnull createNetwork(NetworkType network_id,
                                   const std::vector<int> &params,
                                   const FloatArrayMap& config) {
  switch (network_id) {
  case kSingleReLUNet:
    return new SingleReLUNetwork(params, config);
  case kSingleConvNet:
    return new SingleConvNetwork(params, config);
  case kSingleBNNet:
    return new SingleBNNetwork(params, config);
  case kSingleMPNet:
    return new SingleMPNetwork(params, config);
  case kSingle1DConvNet:
    return new Single1DConvNetwork(params, config);
  case kODNet:
    return new ODNetwork(params, config);
  case kSingleDropOutNet:
    return new SingleDropOutNetwork(params, config);
  case kActivityClassifierNet:
    return new ActivityClassifierNetwork(params, config);
  case kSingleFcNet:
    return new SingleFcNetwork(params, config);
  case kSingleSoftMaxNet:
    return new SingleSoftMaxNetwork(params, config);
  case kSingleLstmNet:
      return new SingleLstmNetwork(params, config);
  default:
    throw std::invalid_argument("Undefined network.");
  }
}

// MPS Network base class
// ---------------------------------------------------------------------------------------
MPSNetwork::~MPSNetwork() {
  for (int i = 0; i < layers.size(); ++i) {
    delete layers[i];
  }
  delete lossLayer;
}

void MPSNetwork::Init(id<MTLDevice> _Nonnull device, id<MTLCommandQueue> cmd_q,
                      const FloatArrayMap &config) {
    
  for (int i = 0; i < layers.size(); ++i) {
    layers[i]->Init(device, cmd_q, config, is_train_, network_mode_ ,(i == layers.size() - 1));
  }
  
  if (lossLayer != nil){
      lossLayer->Init(device, cmd_q, config, true, network_mode_, true);
  }
}

MPSImageBatch *_Nonnull MPSNetwork::Forward(MPSImageBatch *_Nonnull src,
                                            id<MTLCommandBuffer> _Nonnull cb,
                                            bool is_train) {
  MPSImageBatch *input = src;
  for (int i = 0; i < layers.size(); ++i) {
      
    // MPSTempImages are created by default with readCount=1. This means
    // that after they are read once - they may be destroyed by the Metal
    // memory manager.
    // The input images are used both by the forward pass kernels, and the
    // backward pass GradientKernels. So we need to increase the readCont
    // by 1, or the backward pass will fail.
    // BN layer uses each image twice - once for calculating batch statistics,
    // and again for the BN kernel itself. So it would need 4 reads altogether,
    // including backward pass.
    int num_remaining_reads = (layers[i]->type == kBN)? 3 : 1;
    MPSImageBatchIncrementReadCount(input, num_remaining_reads);
      
    layers[i]->Forward(input, cb, is_train);
    input = layers[i]->fwd_output;
  }

  return input;
}

MPSImageBatch *_Nonnull MPSNetwork::Backward(MPSImageBatch *_Nonnull src,
                                             id<MTLCommandBuffer> _Nonnull cb) {
  assert(is_train_ && "Backward operation is not supported for non-training networks");

  MPSImageBatch *input = src;
  assert(layers.size() > 0);
  int sid = layers.size() - 1;
  for (int i = sid; i >= 0; --i) {
    if (layers[i]->type == kBN)
    {
        MPSImageBatchIncrementReadCount(input, 1);
    }
    layers[i]->Backward(input, cb);
    input = layers[i]->bwd_output;
  }
  return input;
}

void MPSNetwork::SyncState(id<MTLCommandBuffer> _Nonnull cb) {
  int sid = layers.size() - 1;
  for (int i = sid; i >= 0; --i) {
    if (layers[i]->type == kConv) {
      for (int j = 0; j < batch_size; ++j) {
        [layers[i]->state[j] synchronizeOnCommandBuffer:cb];
      }
    }
  }
}

void MPSNetwork::Load(const FloatArrayMap &weights) {
  for (int i = 0; i < layers.size(); ++i) {
    layers[i]->Load(weights);
  }
}

void MPSNetwork::Export(
    std::unordered_map<std::string,
                       std::tuple<std::string, float *, int, std::vector<int>>>
        &table) {
  for (int i = 0; i < layers.size(); ++i) {
    layers[i]->Export(table);
  }
}

void MPSNetwork::Update(MPSUpdater *_Nonnull updater) {
  updater->NewIteration();
  for (int i = 0; i < layers.size(); ++i) {
    layers[i]->Update(updater, i);
  }
}

void MPSNetwork::GpuUpdate(id<MTLCommandBuffer> _Nonnull cb){
    for (int i = 0; i < layers.size(); ++i) {
        layers[i]->GpuUpdate(cb);
    }
}

int MPSNetwork::NumParams() {
  int ret = 0;
  for (int i = 0; i < layers.size(); ++i) {
    LayerType type = layers[i]->type;
    switch (type) {
    case kConv:
      ret += 2;
      break;
    case kBN:
      ret += 4;
      break;
    case kLSTM:
      ret += 12;
    default:
      break;
    }
  }
  return ret;
}

MPSImageBatch *_Nonnull MPSNetwork::Loss(MPSImageBatch *_Nonnull src,
                                         MPSCNNLossLabelsBatch *_Nonnull labels,
                                         id<MTLCommandBuffer> _Nonnull cb) {
  if (lossLayer == nil) {
    throw std::invalid_argument(
        "Calling network Loss without defining a loss layer");
  }

  lossLayer->Loss(src, labels, cb);
  return lossLayer->bwd_output; // Loss gradients
}

