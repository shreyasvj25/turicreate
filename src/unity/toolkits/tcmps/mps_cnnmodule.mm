#include "mps_cnnmodule.h"

#include <iostream>

namespace {

MPSImageBatch * _Nonnull CreateImageBatch(id<MTLDevice> _Nonnull device,
                                          MPSImageDescriptor * _Nonnull desc,
                                          NSUInteger batchSize) {
  NSMutableArray<MPSImage*> *result = [[NSMutableArray alloc] initWithCapacity:batchSize];
  for (NSUInteger i = 0; i < batchSize; ++i) {
    [result addObject:[[MPSImage alloc] initWithDevice:device imageDescriptor:desc]];
  }
  return [result copy];
}

}  // anonymous namespace

MPSCNNModule::MPSCNNModule() {
  dev_ = MetalDevice::Get()->dev;
  assert(dev_ && "No valid Metal device. Availability should be checked before creating MPSCNNModule.");
  id<MTLCommandQueue> cq = [dev_ newCommandQueue];
  assert(cq);
  cmd_queue_ = cq;

#if VERBOSE
  NSLog(@"Selected dev: %@", dev_.name);
#endif
}

void MPSCNNModule::Init(int network_id, int n, int c_in, int h_in, int w_in,
                        int c_out, int h_out, int w_out, int updater_id,
                        const FloatArrayMap &config) {

  // Save output shape, used for initializing the labels (that can not
  // be pre-initialized without the data)
  output_chn_ = c_out;
  output_width_ = w_out;

  input_desc_ = [MPSImageDescriptor
      imageDescriptorWithChannelFormat:MPSImageFeatureChannelFormatFloat32
                                 width:w_in
                                height:h_in
                       featureChannels:c_in
                        numberOfImages:1
                                 usage:MTLTextureUsageShaderWrite |
                                       MTLTextureUsageShaderRead];

  input_ = CreateImageBatch(dev_, input_desc_, n);

  // output_ and top_grad_ should only be allocated in Test mode, where they are used
  // as inputs coming externally from python
  LowLevelMode network_mode = (LowLevelMode) get_array_map_scalar(config, "mode", kLowLevelModeTrain);

  if (kLowLevelModeTest == network_mode){
      MPSImageDescriptor *output_desc = [MPSImageDescriptor
          imageDescriptorWithChannelFormat:MPSImageFeatureChannelFormatFloat32
                                     width:w_out
                                    height:h_out
                           featureChannels:c_out
                            numberOfImages:1
                                     usage:MTLTextureUsageShaderWrite |
                                           MTLTextureUsageShaderRead];

      output_ = CreateImageBatch(dev_, output_desc_, n);
      top_grad_ = CreateImageBatch(dev_, output_desc_, n);
  }

  network_ = createNetwork((NetworkType)network_id, {n, h_in, w_in, c_in, h_out, w_out, c_out}, config);
  network_->batch_size = n;
  network_->Init(dev_, cmd_queue_, config);
  SetupUpdater(updater_id);
}

MPSCNNModule::~MPSCNNModule() {
  delete network_;
  delete updater_;
}

MPSCNNModule::Batch* MPSCNNModule::StartBatch(int batch_id) {
  if (active_batches_.find(batch_id) != active_batches_.end()) {
    throw std::logic_error("Cannot start batch with ID already in use");
  }

  Batch& batch = active_batches_[batch_id];
  if (free_batches_.empty()) {
    // Allocate a new input MPSImageBatch.
    batch.input = CreateImageBatch(dev_, input_desc_, network_->batch_size);
  } else {
    batch = std::move(free_batches_.back());
    free_batches_.pop_back();

    // Recycle MPSImageBatch allocations from a previous batch.
    assert(batch.input);
  }

  return &batch;
}

void MPSCNNModule::WaitForBatch(int batch_id, float *forward_out,
                                float *loss_out) {
  std::map<int, Batch>::iterator it = active_batches_.find(batch_id);
  if (it == active_batches_.end()) {
    throw std::logic_error("Cannot wait for batch with unknown ID");
  }

  Batch &batch = it->second;
  assert(batch.command_buffer);
  [batch.command_buffer waitUntilCompleted];

  if (forward_out) {
    MPSImage2Blob(forward_out, batch.output);
  }

  if (loss_out) {
    MPSImage2Blob(loss_out, batch.loss_images);
  }

  batch.command_buffer = nil;
  batch.output = nil;
  batch.top_grad = nil;
  batch.loss_images = nil;

  free_batches_.push_back(std::move(batch));
  active_batches_.erase(it);
}

void MPSCNNModule::Forward(void *ptr, int64_t sz, int64_t *shape, int dim,
                           float *out, bool is_train) {
  // may check shape here
  Blob2MPSImage((float *)ptr, input_);
  @autoreleasepool {
    id<MTLCommandBuffer> commandBuffer = [cmd_queue_ commandBuffer];


    // run network
    output_ = network_->Forward(input_, commandBuffer, is_train);

    for (NSUInteger i = 0; i < [output_ count]; ++i) {
        [output_[i] synchronizeOnCommandBuffer:commandBuffer];
    }

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    // copy output
    MPSImage2Blob(out, output_);
  }
}

void MPSCNNModule::Backward(void *ptr, size_t sz, int64_t *shape, int dim,
                            float *out) {
  Blob2MPSImage((float *)ptr, top_grad_);
  @autoreleasepool {
    id<MTLCommandBuffer> commandBuffer = [cmd_queue_ commandBuffer];


    // run backward
    MPSImageBatch *bottom_grad = network_->Backward(top_grad_, commandBuffer);
    for (NSUInteger i = 0; i < [bottom_grad count]; ++i) {
        [bottom_grad[i] synchronizeOnCommandBuffer:commandBuffer];
    }
    network_->SyncState(commandBuffer);
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    // copy output
    MPSImage2Blob(out, bottom_grad);
  }
}

void MPSCNNModule::Loss(void *_Nonnull ptr, size_t sz, int64_t *_Nonnull shape, int dim,
                        void *_Nonnull label_ptr, size_t label_sz, int64_t *_Nonnull label_shape, int label_dim,
                        void *_Nonnull weight_ptr, size_t weight_sz, int64_t *_Nonnull weight_shape, int weight_dim,
                        bool loss_image_required,
                        float *_Nonnull out) {
  Blob2MPSImage((float *)ptr, output_);
  @autoreleasepool {
      id<MTLCommandBuffer> commandBuffer = [cmd_queue_ commandBuffer];


      // Creating labels batch
      MPSCNNLossLabelsBatch *labels =
          initLossLabelsBatch(dev_, (float *)label_ptr, (float *)weight_ptr,
                              network_->batch_size, output_width_, output_chn_);

      // Calc loss
      top_grad_ = network_->Loss(output_, labels, commandBuffer);

      for (NSUInteger i = 0; i < [top_grad_ count]; ++i) {
        [top_grad_[i] synchronizeOnCommandBuffer:commandBuffer];
      }
      
      if (loss_image_required){
          loss_images_ = ExtractLossImages(labels, network_->batch_size, commandBuffer);
      }

      [commandBuffer commit];
      [commandBuffer waitUntilCompleted];

      // copy output
      MPSImage2Blob(out, top_grad_);
  }
}

void MPSCNNModule::Forward(void * _Nonnull ptr, size_t sz, int64_t * _Nonnull shape, int dim,
                           void * _Nonnull label_ptr, size_t label_sz, int64_t * _Nonnull label_shape, int label_dim,
                           void *_Nonnull weight_ptr, size_t weight_sz, int64_t *_Nonnull weight_shape, int weight_dim,
                           bool loss_image_required, bool is_train,
                           float * _Nonnull out) {
    
    TrainingWithLoss(/* batch */ nullptr, ptr, sz, shape, dim, label_ptr,
                     label_sz, label_shape, label_dim,
                     weight_ptr, weight_sz, weight_shape, weight_dim,
                     loss_image_required, /* wait_until_completed */ true, out,
                     /* do_backward */ false, is_train);
}
void MPSCNNModule::ForwardBackward(void * _Nonnull ptr, size_t sz, int64_t * _Nonnull shape, int dim,
                                   void * _Nonnull label_ptr, size_t label_sz, int64_t * _Nonnull label_shape, int label_dim,
                                   void *_Nonnull weight_ptr, size_t weight_sz, int64_t *_Nonnull weight_shape, int weight_dim,
                                   bool loss_image_required,
                                   float * _Nonnull out) {
    
    TrainingWithLoss(/* batch */ nullptr, ptr, sz, shape, dim, label_ptr,
                     label_sz, label_shape, label_dim,
                     weight_ptr, weight_sz, weight_shape, weight_dim,
                     loss_image_required, /* wait_until_completed */ true, out,
                     /* do_backward */ true);
}

void MPSCNNModule::BeginForwardBatch(
    int batch_id, void *ptr, size_t sz, int64_t *shape, int dim,
    void *label_ptr, size_t label_sz, int64_t *label_shape, int label_dim,
    void *weight_ptr, size_t weight_sz, int64_t *weight_shape, int weight_dim,
    bool loss_image_required, bool is_train) {
  Batch* batch = StartBatch(batch_id);
  TrainingWithLoss(batch, ptr, sz, shape, dim, label_ptr, label_sz, label_shape,
                   label_dim, weight_ptr, weight_sz, weight_shape, weight_dim,
                   loss_image_required, /* wait_until_completed */ false,
                   /* out */ nullptr, /* do_backward */ false, is_train);
}

void MPSCNNModule::BeginForwardBackwardBatch(
    int batch_id, void *ptr, size_t sz, int64_t *shape, int dim,
    void *label_ptr, size_t label_sz, int64_t *label_shape, int label_dim,
    void *weight_ptr, size_t weight_sz, int64_t *weight_shape, int weight_dim,
    bool loss_image_required) {
  Batch* batch = StartBatch(batch_id);
  TrainingWithLoss(batch, ptr, sz, shape, dim, label_ptr, label_sz, label_shape,
                   label_dim, weight_ptr, weight_sz, weight_shape, weight_dim,
                   loss_image_required, /* wait_until_completed */ false,
                   /* out */ nullptr, /* do_backward */ true);
}

void MPSCNNModule::TrainingWithLoss(
      Batch *batch, void *ptr, size_t sz, int64_t *shape, int dim,
      void *label_ptr, size_t label_sz, int64_t *label_shape, int label_dim,
      void *weight_ptr, size_t weight_sz, int64_t *weight_shape, int weight_dim,
      bool loss_image_required, bool wait_until_completed, float *out,
      bool do_backward, bool is_train) {
    // may check shape here
    if (batch) {
      input_ = batch->input;
    }
    Blob2MPSImage((float *)ptr, input_);
    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = [cmd_queue_ commandBuffer];
        // Creating labels batch
        MPSCNNLossLabelsBatch *labels =
            initLossLabelsBatch(dev_, (float *)label_ptr, (float *)weight_ptr,
                                network_->batch_size, output_width_, output_chn_);
        // run foward pass
        output_ = network_->Forward(input_, commandBuffer, is_train);
        
        // Calc loss
        top_grad_ = network_->Loss(output_, labels, commandBuffer);
        
        
        if (loss_image_required){
            loss_images_ = ExtractLossImages(labels, network_->batch_size, commandBuffer);
        }
        
        if (do_backward){
            // run backward pass
            MPSImageBatch *bottom_grad = network_->Backward(top_grad_, commandBuffer);
            if (kLowLevelModeTest == network_->network_mode_){
                for (NSUInteger i = 0; i < [bottom_grad count]; ++i) {
                    [bottom_grad[i] synchronizeOnCommandBuffer:commandBuffer];
                }
            }
        }
        
        for (NSUInteger i = 0; i < [output_ count]; ++i) {
            [output_[i] synchronizeOnCommandBuffer:commandBuffer];
        }

        [commandBuffer commit];
        
        if (wait_until_completed) {
          [commandBuffer waitUntilCompleted];
        }

        if (out) {
          assert(wait_until_completed && "Error: Must wait for completion before reading output.");
          MPSImage2Blob(out, output_);
        }

        if (batch) {
          batch->command_buffer = commandBuffer;
          batch->output = output_;
          batch->top_grad = top_grad_;
          batch->loss_images = loss_images_;
        }
    }
}

void MPSCNNModule::GetLossImages(float *_Nonnull out) {
  assert(loss_images_ && "Error: No Loss image found. Please call Loss() with loss_image_required=true.");
    
  // copy output
  MPSImage2Blob(out, loss_images_);
}

void MPSCNNModule::Update() { network_->Update(updater_); }

void MPSCNNModule::GpuUpdate(){
    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = [cmd_queue_ commandBuffer];
        network_->GpuUpdate(commandBuffer);
        
        [commandBuffer commit];

        // Don't bother waiting for this command buffer to complete. Any
        // observation or dependency on the results of this update must entail
        // another later command, for which the observer must wait.
    }
}

void MPSCNNModule::Load(const FloatArrayMap &weights) {
  network_->Load(weights);
}
void MPSCNNModule::Export() {
  table_.clear();
  network_->Export(table_);
}
int MPSCNNModule::NumParams() { return network_->NumParams(); }

void MPSCNNModule::SetupUpdater(int updater_id) {
  updater_ = createUpdater(updater_id);
  updater_->Init(network_->layers, {1e-3});
}

void MPSCNNModule::Blob2MPSImage(float *ptr, MPSImageBatch *batch) {
  // add size chcek later
  assert([batch count] > 0);
  MPSImage *img = batch[0];
  int stride = [img width] * [img height] * [img featureChannels];
  for (int i = 0; i < [batch count]; ++i) {
    MPSImage *img = batch[i];
    [img writeBytes:ptr + stride * i
         dataLayout:(MPSDataLayoutHeightxWidthxFeatureChannels)imageIndex:0];
  }
}

void MPSCNNModule::MPSImage2Blob(float *ptr, MPSImageBatch *batch) {
  // add size chcek later
  assert([batch count] > 0);
  MPSImage *img = batch[0];
  int stride = [img width] * [img height] * [img featureChannels];
  for (int i = 0; i < [batch count]; ++i) {
    MPSImage *img = batch[i];
    [img readBytes:ptr + stride * i
        dataLayout:(MPSDataLayoutHeightxWidthxFeatureChannels)imageIndex:0];
  }
}

MPSCNNLossLabelsBatch *_Nonnull MPSCNNModule::initLossLabelsBatch(
      id<MTLDevice> _Nonnull device, float *_Nonnull labels_ptr, float *_Nonnull weights_ptr,
      int batch_size, int seq_len, int num_classes) {
    
  MPSCNNLossLabelsBatch *labels = @[];

  // label size in each batch is 1 (height) * seq_len (width) * num_classes
  // (output channels)
  int label_size = 1 * seq_len * num_classes;

    std::vector<float> sequenceLabels(label_size);
    std::vector<float> sequenceWeights(label_size);
    float *labelsBuffer = sequenceLabels.data();
    float *weightBuffer = sequenceWeights.data();

  MTLSize labelMtlSize = MTLSizeMake(seq_len, 1, num_classes);

  for (int batch_idx = 0; batch_idx < batch_size; batch_idx++) {

    // Init the data buffer for a new batch
    memset(labelsBuffer, 0.0, label_size * sizeof(float));

    for (int seq_idx = 0; seq_idx < seq_len; seq_idx++) {
      // Create a hot one encoded representation of the label, per sequence
      int src_index = batch_idx * seq_len + seq_idx;
      int dst_index = seq_idx * num_classes;
      int nClassLabelVal = (int) labels_ptr[src_index];
      labelsBuffer[dst_index + nClassLabelVal] = 1.f;
      
      // Repeat each weight value num_classes time - so each of the channel
      // in the one hot encoded represantion will have the same weight
      float weightVal = weights_ptr[src_index];
      for (int chn_idx = 0; chn_idx < num_classes; chn_idx++){
          weightBuffer[dst_index + chn_idx] = weightVal;
      }
    }

    NSData *labelsData =
        [NSData dataWithBytes:labelsBuffer length:label_size * sizeof(float)];

    MPSCNNLossDataDescriptor *labelsDescriptor = [MPSCNNLossDataDescriptor
        cnnLossDataDescriptorWithData:labelsData
                               layout:MPSDataLayoutHeightxWidthxFeatureChannels
                                 size:labelMtlSize];
    
    NSData *weightsData =
          [NSData dataWithBytes:weightBuffer length:label_size * sizeof(float)];
    
    MPSCNNLossDataDescriptor *weightsDescriptor = [MPSCNNLossDataDescriptor
                                                   cnnLossDataDescriptorWithData:weightsData
                                                                          layout:MPSDataLayoutHeightxWidthxFeatureChannels
                                                                            size:labelMtlSize];
      
    MPSCNNLossLabels *lossState =
      [[MPSCNNLossLabels alloc] initWithDevice:device
                                 lossImageSize:{1, 1, 1}
                              labelsDescriptor:labelsDescriptor
                             weightsDescriptor:weightsDescriptor];

    labels = [labels arrayByAddingObject:lossState];
  }

  return labels;
}

MPSImageBatch *_Nonnull MPSCNNModule::ExtractLossImages(MPSCNNLossLabelsBatch *_Nonnull labels, int batch_size,
                                                        id<MTLCommandBuffer> cb) {
    MPSImageBatch *lossImage = @[];
    
    // Sync the LossLabels so loss image can be extracted
    for (NSUInteger i = 0; i < [labels count]; ++i) {
        [labels[i] synchronizeOnCommandBuffer:cb];
    }
    
    for (NSUInteger i = 0; i < batch_size; i++) {
        lossImage = [lossImage arrayByAddingObject:[labels[i] lossImage]];
    }
    return lossImage;
}

