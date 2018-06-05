#include "mps_graph_networks.h"
#include "mps_graph_layers.h"

@interface MyHandle : NSObject <MPSHandle>
+ (nullable instancetype)handleWithLabel:(NSString *)label;
- (nullable instancetype)initWithLabel:(NSString *)label;
- (NSString *)label;
- (BOOL)isEqual:(id)what;
- (nullable instancetype)initWithCoder:(NSCoder *)aDecoder;
- (void)encodeWithCoder:(NSCoder *)aCoder;
+ (BOOL)supportsSecureCoding;
@end

MPSGraphNetwork *_Nonnull createNetworkGraph(GraphNetworkType network_id,
                                             const std::vector<int> &params,
                                             const FloatArrayMap &config) {
  switch (network_id) {
  case kSingleReLUGraphNet:
    return new SingleReLUNetworkGraph(params, config);
  case kSingleConvGraphNet:
    return new SingleConvNetworkGraph(params, config);
  case kSingleMPGraphNet:
    return new SingleMPNetworkGraph(params, config);
  case kSingleBNGraphNet:
    return new SingleBNNetworkGraph(params, config);
  case kODGraphNet:
    return new ODNetworkGraph(params, config);
  default:
    throw std::invalid_argument("Undefined network.");
  }
}

// MPS Network base class
// ---------------------------------------------------------------------------------------
MPSGraphNetwork::~MPSGraphNetwork() {
  for (int i = 0; i < layers.size(); ++i) {
    delete layers[i];
  }
}

void MPSGraphNetwork::Init(id<MTLDevice> _Nonnull device,
                           id<MTLCommandQueue> cmd_queue,
                           GraphMode mode,
                           const FloatArrayMap &config,
                           const FloatArrayMap &weights) {
  for (int i = 0; i < layers.size(); ++i) {
    layers[i]->Init(device, cmd_queue, config, weights);
  }
  input_node =
      [MPSNNImageNode nodeWithHandle:[MyHandle handleWithLabel:@"input"]];
  MPSNNImageNode *src = input_node;
  for (int i = 0; i < layers.size(); ++i) {
    layers[i]->InitFwd(src);
    src = layers[i]->fwd_img_node;
  }
  if (mode == kGraphModeTrain || mode == kGraphModeTrainReturnGrad) {
    // Construct forward-backward graph
    if (loss_layer_) {
      loss_layer_->Init(device, cmd_queue, config, weights);
      loss_layer_->labels_node.handle = [MyHandle handleWithLabel:@"labels"];
      loss_layer_->InitFwd(src);
      src = loss_layer_->fwd_img_node;
      loss_layer_->InitBwd(src);
      src = loss_layer_->bwd_img_node;
    } else {
      grad_node = [MPSNNImageNode nodeWithHandle:[MyHandle handleWithLabel:@"grad"]];
      src = grad_node;
    }
    if (layers.size() > 0) {
      for (int i = (int)layers.size() - 1; i >= 0; --i) {
#if VERBOSE
        NSLog(@"i = %d, src = %p", i, src);
#endif
        layers[i]->InitBwd(src);
        src = layers[i]->bwd_img_node;
      }
    }
    graph = [[MPSNNGraph alloc] initWithDevice:device
                                   resultImage:layers[0]->bwd_img_node
                           resultImageIsNeeded:(mode == kGraphModeTrainReturnGrad)];
  } else {
    // Construct pure inference graph
    graph = [[MPSNNGraph alloc] initWithDevice:device
                                   resultImage:layers[layers.size() - 1]->fwd_img_node
                           resultImageIsNeeded:YES];
  }

#if VERBOSE
  NSLog(@"%@", [graph debugDescription]);
#endif
}

MPSImageBatch *MPSGraphNetwork::RunGraph(id<MTLCommandBuffer> cb,
                                    NSDictionary *inputs) {
  NSArray *input_to_graph = @[];
  for (int i = 0; i < graph.sourceImageHandles.count; ++i) {
    // check keys
    input_to_graph = [input_to_graph
        arrayByAddingObject:[inputs objectForKey:[graph.sourceImageHandles[i]
                                                     label]]];
  }
  MPSImageBatch *ret = [graph encodeBatchToCommandBuffer:cb
                                            sourceImages:input_to_graph
                                            sourceStates:nil
                                      intermediateImages:nil
                                       destinationStates:nil];

  return ret;
}

MPSImageBatch *MPSGraphNetwork::RunGraph(id<MTLCommandBuffer> cb, MPSImageBatch *src,
                                         MPSCNNLossLabelsBatch *loss_state) {
  MPSImageBatch *ret =
      [graph encodeBatchToCommandBuffer:cb
                           sourceImages:@[ src ]
                           sourceStates:@[ loss_state ]
                     intermediateImages:nil
                      destinationStates:nil]; // need convGradientStates maybe
  return ret;
}

void MPSGraphNetwork::Export(
    std::unordered_map<std::string,
                       std::tuple<std::string, float *, int, std::vector<int>>>
        &table) {
  for (int i = 0; i < layers.size(); ++i) {
    layers[i]->Export(table);
  }
}

int MPSGraphNetwork::NumParams() {
  int ret = 0;
  for (int i = 0; i < layers.size(); ++i) {
    LayerType type = layers[i]->type;
    switch (type) {
    case kConv:
      {
        ConvGraphLayer *convLayer = reinterpret_cast<ConvGraphLayer*>(layers[i]);
        if (convLayer->use_bias) {
          ret += 2;
        } else {
          ret += 1;
        }
      }
      break;
    case kBN:
      ret += 4;
      break;
    default:
      break;
    }
  }
  return ret;
}

@implementation MyHandle {
  NSString *_label;
}

+ (instancetype)handleWithLabel:(NSString *)label {
  return [[self alloc] initWithLabel:label];
}

- (instancetype)initWithLabel:(NSString *)label {
  self = [super init];
  if (nil == self)
    return self;
  _label = label;
  return self;
}

- (NSString *)label {
  return _label;
}

- (BOOL)isEqual:(id)what {
  return [_label isEqual:((MyHandle *)what).label];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super init];
  if (nil == self)
    return self;

  _label =
      [aDecoder decodeObjectOfClass:NSString.class forKey:@"MyHandleLabel"];
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [aCoder encodeObject:_label forKey:@"MyHandleLabel"];
}

+ (BOOL)supportsSecureCoding {
  return YES;
}

@end
