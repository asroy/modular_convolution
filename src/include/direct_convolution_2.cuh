#pragma once
#include "constant_tensor_descriptor.cuh"
#include "blockwise_tensor_op.cuh"
#include "blockwise_convolution.cuh"

template <class TFloat,
          class InGlobalDesc,
          class WeiGlobalDesc,
          class OutGlobalDesc,
          unsigned OutTileSizeH,
          unsigned OutTileSizeW,
          unsigned NPerBlock,
          unsigned KPerBlock,
          unsigned CPerBlock,
          unsigned YPerBlock,
          unsigned XPerBlock,
          unsigned NBlockOpLen0,
          unsigned NBlockOpLen1,
          unsigned NBlockOpLen2,
          unsigned NBlockOpLen3,
          unsigned BlockSize,
          unsigned GridSize>
__global__ void gridwise_convolution(InGlobalDesc,
                                     TFloat* const __restrict__ p_in_global,
                                     WeiGlobalDesc,
                                     TFloat* const __restrict__ p_wei_global,
                                     OutGlobalDesc,
                                     TFloat* __restrict__ p_out_global)
{
    constexpr auto I0 = Index<0>{};
    constexpr auto I1 = Index<1>{};
    constexpr auto I2 = Index<2>{};
    constexpr auto I3 = Index<3>{};

    constexpr auto in_global_desc  = InGlobalDesc{};
    constexpr auto wei_global_desc = WeiGlobalDesc{};
    constexpr auto out_global_desc = OutGlobalDesc{};

    constexpr unsigned S = wei_global_desc.GetLength(I2);
    constexpr unsigned R = wei_global_desc.GetLength(I3);

    constexpr unsigned HoPerBlock = OutTileSizeH * YPerBlock;
    constexpr unsigned WoPerBlock = OutTileSizeW * XPerBlock;

    constexpr unsigned HiPerBlock = YPerBlock * OutTileSizeH + S - 1;
    constexpr unsigned WiPerBlock = XPerBlock * OutTileSizeW + R - 1;

    constexpr unsigned NBlockWork = (out_global_desc.GetLength(I0) + NPerBlock - 1) / NPerBlock;
    constexpr unsigned KBlockWork = (out_global_desc.GetLength(I1) + KPerBlock - 1) / KPerBlock;
    constexpr unsigned YBlockWork = (out_global_desc.GetLength(I2) + HoPerBlock - 1) / HoPerBlock;
    constexpr unsigned XBlockWork = (out_global_desc.GetLength(I3) + WoPerBlock - 1) / WoPerBlock;

    constexpr auto in_block_src_desc = make_ConstantTensorDescriptor(
        Sequence<NPerBlock, CPerBlock, HiPerBlock, WiPerBlock>{}, in_global_desc.GetStrides());

    constexpr auto wei_block_src_desc = make_ConstantTensorDescriptor(
        Sequence<KPerBlock, CPerBlock, S, R>{}, wei_global_desc.GetStrides());

    constexpr auto out_block_src_desc = make_ConstantTensorDescriptor(
        Sequence<NPerBlock, KPerBlock, HoPerBlock, WoPerBlock>{}, out_global_desc.GetStrides());

    constexpr auto in_block_dst_desc =
        make_ConstantTensorDescriptor(in_block_src_desc.GetLengths());
    constexpr auto wei_block_dst_desc =
        make_ConstantTensorDescriptor(wei_block_src_desc.GetLengths());
    constexpr auto out_block_dst_desc =
        make_ConstantTensorDescriptor(out_block_src_desc.GetLengths());

    constexpr unsigned in_block_size  = in_block_dst_desc.GetElementSpace();
    constexpr unsigned wei_block_size = wei_block_dst_desc.GetElementSpace();
    constexpr unsigned out_block_size = out_block_dst_desc.GetElementSpace();

    __shared__ TFloat p_in_block[in_block_size];
    __shared__ TFloat p_wei_block[wei_block_size];
    __shared__ TFloat p_out_block[out_block_size];

    const unsigned block_id = blockIdx.x;

    unsigned itmp            = block_id;
    unsigned n_block_work_id = itmp / (KBlockWork * YBlockWork * XBlockWork);
    itmp -= n_block_work_id * (KBlockWork * YBlockWork * XBlockWork);
    unsigned k_block_work_id = itmp / (YBlockWork * XBlockWork);
    itmp -= k_block_work_id * (YBlockWork * XBlockWork);
    unsigned y_block_work_id = itmp / XBlockWork;
    unsigned x_block_work_id = itmp - y_block_work_id * XBlockWork;

    unsigned n_block_work_begin = n_block_work_id * NPerBlock;
    unsigned k_block_work_begin = k_block_work_id * KPerBlock;
    unsigned y_block_work_begin = y_block_work_id * YPerBlock;
    unsigned x_block_work_begin = x_block_work_id * XPerBlock;

    unsigned ho_block_work_begin = y_block_work_begin * OutTileSizeH;
    unsigned wo_block_work_begin = x_block_work_begin * OutTileSizeW;

    unsigned hi_block_work_begin = ho_block_work_begin; // minus padding
    unsigned wi_block_work_begin = wo_block_work_begin; // minus padding

#if 0
    if(threadIdx.x == 0)
    {
        print_ConstantTensorDescriptor( in_global_desc, "gridwise_convolution:  in_global_desc: ");
        print_ConstantTensorDescriptor(wei_global_desc, "gridwise_convolution: wei_global_desc: ");
        print_ConstantTensorDescriptor(out_global_desc, "gridwise_convolution: out_global_desc: ");
        print_ConstantTensorDescriptor( in_block_src_desc, "gridwise_convolution:  in_block_src_desc: ");
        print_ConstantTensorDescriptor(wei_block_src_desc, "gridwise_convolution: wei_block_src_desc: ");
        print_ConstantTensorDescriptor(out_block_src_desc, "gridwise_convolution: out_block_src_desc: ");
        print_ConstantTensorDescriptor( in_block_dst_desc, "gridwise_convolution:  in_block_dst_desc: ");
        print_ConstantTensorDescriptor(wei_block_dst_desc, "gridwise_convolution: wei_block_dst_desc: ");
        print_ConstantTensorDescriptor(out_block_dst_desc, "gridwise_convolution: out_block_dst_desc: ");

        printf("NBlockWork %u, KBlockWork %u, YBlockWork %u, XBlockWork %u \t"
               "block_id %u, n_block_work_id %u, k_block_work_id %u, y_block_work_id %u, "
               "x_block_work_id %u\n",
               NBlockWork,
               KBlockWork,
               YBlockWork,
               XBlockWork,
               block_id,
               n_block_work_id,
               k_block_work_id,
               y_block_work_id,
               x_block_work_id);
    }
#endif

    auto f_set0 = [](TFloat& v) { v = TFloat(0); };
    auto f_copy = [](const TFloat& src, TFloat& dst) { dst = src; };
    auto f_accu = [](const TFloat& src, TFloat& dst) { dst += src; };

    // set output tensor in LDS to 0
    blockwise_4d_tensor_op_unary<TFloat,
                                 decltype(out_block_dst_desc),
                                 NBlockOpLen0,
                                 NBlockOpLen1,
                                 NBlockOpLen2,
                                 NBlockOpLen3,
                                 decltype(f_set0),
                                 BlockSize>(out_block_dst_desc, p_out_block, f_set0);

    for(unsigned c_block_work_begin = 0; c_block_work_begin < in_global_desc.GetLength(I1);
        c_block_work_begin += CPerBlock)
    {

        // copy input tensor to LDS
        blockwise_4d_tensor_op_binary<TFloat,
                                      decltype(in_block_src_desc),
                                      decltype(in_block_dst_desc),
                                      NBlockOpLen0,
                                      NBlockOpLen1,
                                      NBlockOpLen2,
                                      NBlockOpLen3,
                                      decltype(f_copy),
                                      BlockSize>(
            in_block_src_desc,
            p_in_global + in_block_src_desc.Get1dIndex(n_block_work_begin,
                                                       c_block_work_begin,
                                                       hi_block_work_begin,
                                                       wi_block_work_begin),
            in_block_dst_desc,
            p_in_block,
            f_copy);

        // copy weight tensor to LDS
        blockwise_4d_tensor_op_binary<TFloat,
                                      decltype(wei_block_src_desc),
                                      decltype(wei_block_dst_desc),
                                      NBlockOpLen0,
                                      NBlockOpLen1,
                                      NBlockOpLen2,
                                      NBlockOpLen3,
                                      decltype(f_copy),
                                      BlockSize>(
            wei_block_src_desc,
            p_wei_global +
                wei_block_src_desc.Get1dIndex(k_block_work_begin, c_block_work_begin, 0, 0),
            wei_block_dst_desc,
            p_wei_block,
            f_copy);

#if 1
        __syncthreads();
#endif

        // blockwise convolution
        blockwise_convolution<TFloat,
                              decltype(in_block_dst_desc),
                              decltype(wei_block_dst_desc),
                              decltype(out_block_dst_desc),
                              OutTileSizeH,
                              OutTileSizeW,
                              BlockSize>(in_block_dst_desc,
                                         p_in_block,
                                         wei_block_dst_desc,
                                         p_wei_block,
                                         out_block_dst_desc,
                                         p_out_block);

#if 1
        __syncthreads();
#endif
    }

    // copy output tensor from LDS to device mem
    blockwise_4d_tensor_op_binary<TFloat,
                                  decltype(out_block_dst_desc),
                                  decltype(out_block_src_desc),
                                  NBlockOpLen0,
                                  NBlockOpLen1,
                                  NBlockOpLen2,
                                  NBlockOpLen3,
                                  decltype(f_copy),
                                  BlockSize>(
        out_block_dst_desc,
        p_out_block,
        out_block_src_desc,
        p_out_global +
            out_block_src_desc.Get1dIndex(
                n_block_work_begin, k_block_work_begin, ho_block_work_begin, wo_block_work_begin),
        f_copy);
}