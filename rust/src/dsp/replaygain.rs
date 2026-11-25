//! ReplayGain 1.0 (David Robinson) Loudness Scanner.
//!
//! Implements exact 10th-order Yule-Walker pre-equalizer and 2nd-order Butterworth
//! high-pass filtering + 50 ms RMS statistical 95th percentile calculation,
//! matching the reference FFmpeg af_replaygain filter bit-for-bit.

/// Precomputed ReplayGain 1.0 Yule-Walker and Butterworth IIR filter coefficients for a discrete sample rate.
struct ReplayGainFreqInfo {
    /// Reference sample rate in Hz.
    sample_rate: u32,
    /// 10th-order Yule-Walker feedforward numerator coefficients.
    b_yule: [f64; 11],
    /// 10th-order Yule-Walker feedback denominator coefficients (`a[0] = 1.0`).
    a_yule: [f64; 11],
    /// 2nd-order Butterworth high-pass feedforward numerator coefficients.
    b_butter: [f64; 3],
    /// 2nd-order Butterworth high-pass feedback denominator coefficients (`a[0] = 1.0`).
    a_butter: [f64; 3],
}

/// Lookup table of reference ReplayGain 1.0 filter coefficient sets from 8 kHz to 192 kHz.
static FREQ_INFOS: [ReplayGainFreqInfo; 20] = [
    ReplayGainFreqInfo {
        sample_rate: 192000,
        b_yule: [0.01184742123123, -0.04631092400086, 0.06584226961238, -0.02165588522478, -0.05656260778952, 0.0860749359276, -0.03375544339786, -0.04216579932754, 0.06416711490648, -0.03444708260844, 0.00697275872241],
        a_yule: [1.0, -5.24727318348167, 10.60821585192244, -8.74127665810413, -1.33906071371683, 8.07972882096606, -5.46179918950847, 0.54318070652536, 0.8745096922428, -0.34656083539754, 0.03034796843589],
        b_butter: [0.99653501465135, -1.99307002930271, 0.99653501465135],
        a_butter: [1.0, -1.99305802314321, 0.99308203546221],
    },
    ReplayGainFreqInfo {
        sample_rate: 176400,
        b_yule: [0.00268568524529, -0.0085237942608, 0.00852704191347, 0.00146116310295, -0.00950855828762, 0.00625449515499, 0.00116183868722, -0.00362461417136, 0.00203961000134, -0.00050664587933, 4.327455427e-05],
        a_yule: [1.0, -5.57512782763045, 12.44291056065794, -12.87462799681221, 3.08554846961576, 6.62493459880692, -7.07662766313248, 2.51175542736441, 0.06731510802735, -0.24567753819213, 0.03961404162376],
        b_butter: [0.99622916581118, -1.99245833162236, 0.99622916581118],
        a_butter: [1.0, -1.99244411238133, 0.99247255086339],
    },
    ReplayGainFreqInfo {
        sample_rate: 144000,
        b_yule: [0.0063968235945, -0.02556437970955, 0.04230854400938, -0.03722462201267, 0.01718514827295, 0.00610592243009, -0.03065965747365, 0.04345745003539, -0.03298592681309, 0.01320937236809, -0.00220304127757],
        a_yule: [1.0, -6.14814623523425, 15.80002457141566, -20.78487587686937, 11.98848552310315, 3.36462015062606, -10.2241986835947, 6.65599702146473, -1.67141861110485, -0.05417956536718, 0.07374767867406],
        b_butter: [0.99538268958706, -1.99076537917413, 0.99538268958706],
        a_butter: [1.0, -1.99074405950505, 0.99078669884321],
    },
    ReplayGainFreqInfo {
        sample_rate: 128000,
        b_yule: [0.00553120584305, -0.02112620545016, 0.03549076243117, -0.03362498312306, 0.01425867248183, 0.01344686928787, -0.03392770787836, 0.0346413645953, -0.02039116051549, 0.00667420794705, -0.00093763762995],
        a_yule: [1.0, -6.14581710839925, 16.04785903675838, -22.19089131407749, 15.24756471580286, -0.52001440400238, -8.0048864169994, 6.60916094768855, -2.37856022810923, 0.33106947986101, 0.00459820832036],
        b_butter: [0.99480702681278, -1.98961405362557, 0.99480702681278],
        a_butter: [1.0, -1.98958708647324, 0.9896410207779],
    },
    ReplayGainFreqInfo {
        sample_rate: 112000,
        b_yule: [0.00528778718259, -0.01893240907245, 0.03185982561867, -0.02926260297838, 0.00715743034072, 0.01985743355827, -0.03222614850941, 0.02565681978192, -0.01210662313473, 0.00325436284541, -0.00044173593001],
        a_yule: [1.0, -6.24932108456288, 17.42344320538476, -27.86819709054896, 26.79087344681326, -13.43711081485123, -0.66023612948173, 6.03658091814935, -4.2492657703031, 1.40829268709186, -0.19480852628112],
        b_butter: [0.99406737810867, -1.98813475621734, 0.99406737810867],
        a_butter: [1.0, -1.98809955990514, 0.98816995252954],
    },
    ReplayGainFreqInfo {
        sample_rate: 96000,
        b_yule: [0.00588138296683, -0.01613559730421, 0.02184798954216, -0.01742490405317, 0.0046463564378, 0.01117772513205, -0.02123865824368, 0.0195935441335, -0.01079720643523, 0.00352183686289, -0.00063124341421],
        a_yule: [1.0, -5.97808823642008, 16.21362507964068, -25.72923730652599, 25.40470663139513, -14.66166287771134, 2.81597484359752, 2.51447125969733, -2.23575306985286, 0.75788151036791, -0.10078025199029],
        b_butter: [0.99308203517541, -1.98616407035082, 0.99308203517541],
        a_butter: [1.0, -1.98611621154089, 0.98621192916075],
    },
    ReplayGainFreqInfo {
        sample_rate: 88200,
        b_yule: [0.02667482047416, -0.11377479336097, 0.23063167910965, -0.30726477945593, 0.33188520686529, -0.33862680249063, 0.3180716153134, -0.2373079692988, 0.12273894790371, -0.03840017967282, 0.00549673387936],
        a_yule: [1.0, -6.31836451657302, 18.31351310801799, -31.88210014815921, 36.5379214697674, -28.23393036467559, 14.24725258227189, -4.04670980012854, 0.18865757280515, 0.25420333563908, -0.06012333531065],
        b_butter: [0.99247255046129, -1.98494510092259, 0.99247255046129],
        a_butter: [1.0, -1.98488843762335, 0.98500176422183],
    },
    ReplayGainFreqInfo {
        sample_rate: 64000,
        b_yule: [0.02613056568174, -0.08128786488109, 0.14937282347325, -0.21695711675126, 0.25010286673402, -0.23162283619278, 0.17424041833052, -0.1029959921668, 0.04258696481981, -0.00977952936493, 0.00105325558889],
        a_yule: [1.0, -5.73625477092119, 16.15249794355035, -29.68654912464508, 39.55706155674083, -39.82524556246253, 30.50605345013009, -17.43051772821245, 7.05154573908017, -1.80783839720514, 0.22127840210813],
        b_butter: [0.98964101933472, -1.97928203866944, 0.98964101933472],
        a_butter: [1.0, -1.97917472731009, 0.9793893500288],
    },
    ReplayGainFreqInfo {
        sample_rate: 56000,
        b_yule: [0.03144914734085, -0.06151729206963, 0.08066788708145, -0.09737939921516, 0.08943210803999, -0.0698998467201, 0.04926972841044, -0.03161257848451, 0.01456837493506, -0.00316015108496, 0.00132807215875],
        a_yule: [1.0, -4.87377313090032, 12.03922160140209, -20.10151118381395, 25.10388534415171, -24.29065560815903, 18.27158469090663, -10.45249552560593, 4.30319491872003, -1.13716992070185, 0.14510733527035],
        b_butter: [0.98816995007392, -1.97633990014784, 0.98816995007392],
        a_butter: [1.0, -1.97619994516973, 0.97647985512594],
    },
    ReplayGainFreqInfo {
        sample_rate: 48000,
        b_yule: [0.038575994352, -0.02160367184185, -0.00123395316851, -9.291677959e-05, -0.01655260341619, 0.02161526843274, -0.02074045215285, 0.00594298065125, 0.00306428023191, 0.00012025322027, 0.00288463683916],
        a_yule: [1.0, -3.84664617118067, 7.81501653005538, -11.34170355132042, 13.05504219327545, -12.28759895145294, 9.4829380631979, -5.87257861775999, 2.75465861874613, -0.86984376593551, 0.13919314567432],
        b_butter: [0.98621192462708, -1.97242384925416, 0.98621192462708],
        a_butter: [1.0, -1.97223372919527, 0.97261396931306],
    },
    ReplayGainFreqInfo {
        sample_rate: 44100,
        b_yule: [0.0541865640643, -0.02911007808948, -0.00848709379851, -0.00851165645469, -0.00834990904936, 0.02245293253339, -0.02596338512915, 0.01624864962975, -0.00240879051584, 0.00674613682247, -0.00187763777362],
        a_yule: [1.0, -3.47845948550071, 6.36317777566148, -8.54751527471874, 9.4769360780128, -8.81498681370155, 6.85401540936998, -4.39470996079559, 2.19611684890774, -0.75104302451432, 0.13149317958808],
        b_butter: [0.98500175787242, -1.97000351574484, 0.98500175787242],
        a_butter: [1.0, -1.96977855582618, 0.9702284756635],
    },
    ReplayGainFreqInfo {
        sample_rate: 37800,
        b_yule: [0.08717879977844, -0.01000374016172, -0.06265852122368, -0.0111932880095, -0.0011427937296, 0.02081333954769, -0.01603261863207, 0.01936763028546, 0.00760044736442, -0.00303979112271, -0.00075088605788],
        a_yule: [1.0, -2.62816311472146, 3.53734535817992, -3.81003448678921, 3.91291636730132, -3.53518605896288, 2.71356866157873, -1.86723311846592, 1.12075382367659, -0.4857408688689, 0.11330544663849],
        b_butter: [0.98252400815195, -1.96504801630391, 0.98252400815195],
        a_butter: [1.0, -1.96474258269041, 0.9653534499174],
    },
    ReplayGainFreqInfo {
        sample_rate: 32000,
        b_yule: [0.15457299681924, -0.09331049056315, -0.06247880153653, 0.02163541888798, -0.05588393329856, 0.04781476674921, 0.00222312597743, 0.03174092540049, -0.01390589421898, 0.00651420667831, -0.00881362733839],
        a_yule: [1.0, -2.37898834973084, 2.84868151156327, -2.64577170229825, 2.23697657451713, -1.67148153367602, 1.00595954808547, -0.45953458054983, 0.16378164858596, -0.05032077717131, 0.0234789740702],
        b_butter: [0.97938932735214, -1.95877865470428, 0.97938932735214],
        a_butter: [1.0, -1.95835380975398, 0.95920349965459],
    },
    ReplayGainFreqInfo {
        sample_rate: 24000,
        b_yule: [0.30296907319327, -0.22613988682123, -0.08587323730772, 0.03282930172664, -0.00915702933434, -0.02364141202522, -0.00584456039913, 0.06276101321749, -8.28086748e-06, 0.00205861885564, -0.02950134983287],
        a_yule: [1.0, -1.61273165137247, 1.0797749225997, -0.2565625775407, -0.1627671912044, -0.22638893773906, 0.39120800788284, -0.22138138954925, 0.04500235387352, 0.02005851806501, 0.00302439095741],
        b_butter: [0.97531843204928, -1.95063686409857, 0.97531843204928],
        a_butter: [1.0, -1.95002759149878, 0.95124613669835],
    },
    ReplayGainFreqInfo {
        sample_rate: 22050,
        b_yule: [0.33642304856132, -0.2557224142557, -0.11828570177555, 0.11921148675203, -0.07834489609479, -0.0046997791438, -0.0058950022444, 0.05724228140351, 0.00832043980773, -0.0163538138454, -0.0176017656815],
        a_yule: [1.0, -1.49858979367799, 0.87350271418188, 0.12205022308084, -0.80774944671438, 0.47854794562326, -0.12453458140019, -0.04067510197014, 0.08333755284107, -0.04237348025746, 0.02977207319925],
        b_butter: [0.97316523498161, -1.94633046996323, 0.97316523498161],
        a_butter: [1.0, -1.94561023566527, 0.94705070426118],
    },
    ReplayGainFreqInfo {
        sample_rate: 18900,
        b_yule: [0.38524531015142, -0.27682212062067, -0.09980181488805, 0.09951486755646, -0.08934020156622, -0.00322369330199, -0.00110329090689, 0.03784509844682, 0.01683906213303, -0.01147039862572, -0.01941767987192],
        a_yule: [1.0, -1.29708918404534, 0.90399339674203, -0.29613799017877, -0.42326645916207, 0.379348874022, -0.37919795944938, 0.23410283284785, -0.03892971758879, 0.00403009552351, 0.03640166626278],
        b_butter: [0.96535326815829, -1.93070653631658, 0.96535326815829],
        a_butter: [1.0, -1.92950577983524, 0.93190729279793],
    },
    ReplayGainFreqInfo {
        sample_rate: 16000,
        b_yule: [0.4491525660845, -0.14351757464547, -0.22784394429749, -0.01419140100551, 0.04078262797139, -0.12398163381748, 0.04097565135648, 0.10478503600251, -0.01863887810927, -0.03193428438915, 0.00541907748707],
        a_yule: [1.0, -0.62820619233671, 0.29661783706366, -0.372563729424, 0.00213767857124, -0.42029820170918, 0.22199650564824, 0.00613424350682, 0.06747620744683, 0.05784820375801, 0.03222754072173],
        b_butter: [0.96454515552826, -1.92909031105652, 0.96454515552826],
        a_butter: [1.0, -1.92783286977036, 0.93034775234268],
    },
    ReplayGainFreqInfo {
        sample_rate: 12000,
        b_yule: [0.56619470757641, -0.75464456939302, 0.1624213774223, 0.16744243493672, -0.18901604199609, 0.3093178284183, -0.27562961986224, 0.00647310677246, 0.08647503780351, -0.0378898455484, -0.00588215443421],
        a_yule: [1.0, -1.04800335126349, 0.29156311971249, -0.26806001042947, 0.00819999645858, 0.45054734505008, -0.33032403314006, 0.0673936833311, -0.04784254229033, 0.01639907836189, 0.01807364323573],
        b_butter: [0.96009142950541, -1.92018285901082, 0.96009142950541],
        a_butter: [1.0, -1.91858953033784, 0.92177618768381],
    },
    ReplayGainFreqInfo {
        sample_rate: 11025,
        b_yule: [0.58100494960553, -0.53174909058578, -0.14289799034253, 0.17520704835522, 0.02377945217615, 0.15558449135573, -0.25344790059353, 0.01628462406333, 0.06920467763959, -0.03721611395801, -0.00749618797172],
        a_yule: [1.0, -0.51035327095184, -0.31863563325245, -0.20256413484477, 0.1472815413433, 0.38952639978999, -0.23313271880868, -0.05246019024463, -0.02505961724053, 0.02442357316099, 0.01818801111503],
        b_butter: [0.95856916599601, -1.91713833199203, 0.95856916599601],
        a_butter: [1.0, -1.9154210807478, 0.91885558323625],
    },
    ReplayGainFreqInfo {
        sample_rate: 8000,
        b_yule: [0.53648789255105, -0.42163034350696, -0.00275953611929, 0.04267842219415, -0.10214864179676, 0.14590772289388, -0.02459864859345, -0.11202315195388, -0.04060034127, 0.0478866554818, -0.02217936801134],
        a_yule: [1.0, -0.2504987195602, -0.43193942311114, -0.03424681017675, -0.04678328784242, 0.26408300200955, 0.15113130533216, -0.17556493366449, -0.18823009262115, 0.05477720428674, 0.0470440968812],
        b_butter: [0.94597685600279, -1.89195371200558, 0.94597685600279],
        a_butter: [1.0, -1.88903307939452, 0.89487434461664],
    },
];

/// Number of 0.01 dB resolution bins in the ReplayGain 1.0 RMS energy histogram (`0.00..=119.99 dB`).
pub const HISTOGRAM_SLOTS: usize = 12000;

/// High-performance ReplayGain 1.0 scanner with register-resident DF1 stereo IIR state
/// and SSE2 `f64x2` vectorization on `x86_64`.
pub struct ReplayGainScanner {
    /// Histogram counting 50 ms RMS energy windows quantized into 0.01 dB bins.
    histogram: Box<[u32; HISTOGRAM_SLOTS]>,
    /// Maximum absolute sample amplitude observed across the analyzed stream.
    peak: f32,
    /// Number of frames per 50 ms RMS integration window.
    window_samples: usize,
    /// Number of frames accumulated in the current 50 ms window.
    cur_window_samples: usize,
    /// Running sum of squared filtered stereo energies in the current 50 ms window.
    cur_window_sum: f64,
    /// Active 10th-order Yule-Walker feedback coefficients (`a_yule`).
    yule_coeff_a: [f64; 11],
    /// Active 10th-order Yule-Walker feedforward coefficients (`b_yule`).
    yule_coeff_b: [f64; 11],
    /// Active 2nd-order Butterworth feedback coefficients (`a_butter`).
    butter_coeff_a: [f64; 3],
    /// Active 2nd-order Butterworth feedforward coefficients (`b_butter`).
    butter_coeff_b: [f64; 3],
    /// Past 10 stereo inputs `[x[n-1], ..., x[n-10]]` where each element is `[L, R]`.
    yule_x: [[f64; 2]; 10],
    /// Past 10 stereo Yule outputs `[y[n-1], ..., y[n-10]]`.
    yule_y: [[f64; 2]; 10],
    /// Past 2 stereo Butterworth inputs `[u[n-1], u[n-2]]`.
    butter_x: [[f64; 2]; 2],
    /// Past 2 stereo Butterworth outputs `[w[n-1], w[n-2]]`.
    butter_y: [[f64; 2]; 2],
}

impl ReplayGainScanner {
    /// Magnitude threshold below which IIR delay-line registers are flushed to zero to prevent denormals.
    const DENORMAL_FLUSH_THRESHOLD: f64 = 1e-18;

    /// Creates a new `ReplayGainScanner` tuned for `sample_rate`.
    pub fn new(sample_rate: u32) -> Self {
        let best = FREQ_INFOS
            .iter()
            .min_by_key(|info| (info.sample_rate as i64 - sample_rate as i64).abs())
            .unwrap_or(&FREQ_INFOS[9]);

        if best.sample_rate != sample_rate {
            crate::map_log!(
                4,
                "[REPLAYGAIN] Using nearest filter table rate {} Hz for input {} Hz",
                best.sample_rate,
                sample_rate
            );
        }

        let window_samples = ((sample_rate as f64 / 20.0).round() as usize).max(1);
        let histogram: Box<[u32; HISTOGRAM_SLOTS]> = vec![0u32; HISTOGRAM_SLOTS]
            .into_boxed_slice()
            .try_into()
            .expect("histogram length matches HISTOGRAM_SLOTS");

        Self {
            histogram,
            peak: 0.0,
            window_samples,
            cur_window_samples: 0,
            cur_window_sum: 1e-16,
            yule_coeff_a: best.a_yule,
            yule_coeff_b: best.b_yule,
            butter_coeff_a: best.a_butter,
            butter_coeff_b: best.b_butter,
            yule_x: [[0.0; 2]; 10],
            yule_y: [[0.0; 2]; 10],
            butter_x: [[0.0; 2]; 2],
            butter_y: [[0.0; 2]; 2],
        }
    }

    /// Flushes near-zero IIR filter history registers to `0.0` to prevent subnormal slowdowns.
    #[inline]
    fn flush_denormals(&mut self) {
        for pair in &mut self.yule_x {
            if pair[0].abs() < Self::DENORMAL_FLUSH_THRESHOLD {
                pair[0] = 0.0;
            }
            if pair[1].abs() < Self::DENORMAL_FLUSH_THRESHOLD {
                pair[1] = 0.0;
            }
        }
        for pair in &mut self.yule_y {
            if pair[0].abs() < Self::DENORMAL_FLUSH_THRESHOLD {
                pair[0] = 0.0;
            }
            if pair[1].abs() < Self::DENORMAL_FLUSH_THRESHOLD {
                pair[1] = 0.0;
            }
        }
        for pair in &mut self.butter_x {
            if pair[0].abs() < Self::DENORMAL_FLUSH_THRESHOLD {
                pair[0] = 0.0;
            }
            if pair[1].abs() < Self::DENORMAL_FLUSH_THRESHOLD {
                pair[1] = 0.0;
            }
        }
        for pair in &mut self.butter_y {
            if pair[0].abs() < Self::DENORMAL_FLUSH_THRESHOLD {
                pair[0] = 0.0;
            }
            if pair[1].abs() < Self::DENORMAL_FLUSH_THRESHOLD {
                pair[1] = 0.0;
            }
        }
    }

    /// Feeds an interleaved PCM float slice `pcm` with `channels` per frame into the scanner.
    pub fn push_slice(&mut self, pcm: &[f32], channels: usize) {
        if pcm.is_empty() || channels == 0 {
            return;
        }
        if channels == 1 {
            self.push_mono_slice(pcm);
            return;
        }
        #[cfg(target_arch = "x86_64")]
        {
            if channels == 2 {
                // SAFETY: SSE2 is architecturally guaranteed on x86_64.
                unsafe { self.push_stereo_slice_sse2(pcm) };
            } else {
                // SAFETY: SSE2 is architecturally guaranteed on x86_64.
                unsafe { self.push_multichannel_slice_sse2(pcm, channels) };
            }
        }
        #[cfg(not(target_arch = "x86_64"))]
        {
            self.push_stereo_scalar_slice(pcm, channels);
        }
    }

    /// Processes a mono `pcm` slice through the ReplayGain filter chain, duplicating channel energy to match stereo.
    fn push_mono_slice(&mut self, pcm: &[f32]) {
        let b = self.yule_coeff_b;
        let a = self.yule_coeff_a;
        let bb = self.butter_coeff_b;
        let ba = self.butter_coeff_a;

        let mut x1 = self.yule_x[0][0];
        let mut x2 = self.yule_x[1][0];
        let mut x3 = self.yule_x[2][0];
        let mut x4 = self.yule_x[3][0];
        let mut x5 = self.yule_x[4][0];
        let mut x6 = self.yule_x[5][0];
        let mut x7 = self.yule_x[6][0];
        let mut x8 = self.yule_x[7][0];
        let mut x9 = self.yule_x[8][0];
        let mut x10 = self.yule_x[9][0];

        let mut y1 = self.yule_y[0][0];
        let mut y2 = self.yule_y[1][0];
        let mut y3 = self.yule_y[2][0];
        let mut y4 = self.yule_y[3][0];
        let mut y5 = self.yule_y[4][0];
        let mut y6 = self.yule_y[5][0];
        let mut y7 = self.yule_y[6][0];
        let mut y8 = self.yule_y[7][0];
        let mut y9 = self.yule_y[8][0];
        let mut y10 = self.yule_y[9][0];

        let mut bx1 = self.butter_x[0][0];
        let mut bx2 = self.butter_x[1][0];
        let mut by1 = self.butter_y[0][0];
        let mut by2 = self.butter_y[1][0];

        let mut peak = self.peak;
        let win_target = self.window_samples;
        let mut win_cnt = self.cur_window_samples;
        let mut win_sum = self.cur_window_sum;

        for &s in pcm {
            let abs_s = s.abs();
            if abs_s > peak {
                peak = abs_s;
            }
            let x0 = s as f64;
            let pre_y = (x0 * b[0] + x1 * b[1])
                + (x2 * b[2] - y2 * a[2])
                + (x3 * b[3] - y3 * a[3])
                + (x4 * b[4] - y4 * a[4])
                + (x5 * b[5] - y5 * a[5])
                + (x6 * b[6] - y6 * a[6])
                + (x7 * b[7] - y7 * a[7])
                + (x8 * b[8] - y8 * a[8])
                + (x9 * b[9] - y9 * a[9])
                + (x10 * b[10] - y10 * a[10]);
            let y0 = pre_y - y1 * a[1];

            x10 = x9;
            x9 = x8;
            x8 = x7;
            x7 = x6;
            x6 = x5;
            x5 = x4;
            x4 = x3;
            x3 = x2;
            x2 = x1;
            x1 = x0;
            y10 = y9;
            y9 = y8;
            y8 = y7;
            y7 = y6;
            y6 = y5;
            y5 = y4;
            y4 = y3;
            y3 = y2;
            y2 = y1;
            y1 = y0;

            let pre_by = y0 * bb[0] + bx1 * bb[1] + bx2 * bb[2] - by2 * ba[2];
            let by0 = pre_by - by1 * ba[1];
            bx2 = bx1;
            bx1 = y0;
            by2 = by1;
            by1 = by0;

            win_sum += 2.0 * (by0 * by0);
            win_cnt += 1;
            if win_cnt >= win_target {
                self.push_window_energy(win_sum, win_cnt);
                win_sum = 1e-16;
                win_cnt = 0;
                if y1.abs() < Self::DENORMAL_FLUSH_THRESHOLD { y1 = 0.0; }
                if y2.abs() < Self::DENORMAL_FLUSH_THRESHOLD { y2 = 0.0; }
                if by1.abs() < Self::DENORMAL_FLUSH_THRESHOLD { by1 = 0.0; }
                if by2.abs() < Self::DENORMAL_FLUSH_THRESHOLD { by2 = 0.0; }
            }
        }

        self.peak = peak;
        self.cur_window_samples = win_cnt;
        self.cur_window_sum = win_sum;
        self.yule_x = [
            [x1, x1],
            [x2, x2],
            [x3, x3],
            [x4, x4],
            [x5, x5],
            [x6, x6],
            [x7, x7],
            [x8, x8],
            [x9, x9],
            [x10, x10],
        ];
        self.yule_y = [
            [y1, y1],
            [y2, y2],
            [y3, y3],
            [y4, y4],
            [y5, y5],
            [y6, y6],
            [y7, y7],
            [y8, y8],
            [y9, y9],
            [y10, y10],
        ];
        self.butter_x = [[bx1, bx1], [bx2, bx2]];
        self.butter_y = [[by1, by1], [by2, by2]];
        self.flush_denormals();
    }

    /// Processes an interleaved stereo `pcm` slice using SSE2 `f64x2` vectorization.
    ///
    /// # Safety
    /// Caller must ensure the CPU supports SSE2 (architecturally guaranteed on `x86_64`).
    #[cfg(target_arch = "x86_64")]
    #[inline]
    unsafe fn push_stereo_slice_sse2(&mut self, pcm: &[f32]) {
        self.push_multichannel_slice_sse2(pcm, 2);
    }

    /// Processes an interleaved `pcm` slice with `channels >= 2` (extracting the first two channels)
    /// using SSE2 `f64x2` vectorization.
    ///
    /// # Safety
    /// Caller must ensure the CPU supports SSE2 (architecturally guaranteed on `x86_64`) and `channels >= 2`.
    #[cfg(target_arch = "x86_64")]
    #[inline(always)]
    unsafe fn push_multichannel_slice_sse2(&mut self, pcm: &[f32], channels: usize) {
        use std::arch::x86_64::*;

        const BLOCK: usize = 32;

        // Duplicate scalar f64 coefficients into [c, c] SSE2 pairs in L1 stack slots so mulpd
        // folds memory loads directly without overflowing 16 architectural XMM registers.
        let b_pairs: [__m128d; 11] = std::array::from_fn(|k| _mm_set1_pd(self.yule_coeff_b[k]));
        let a_pairs: [__m128d; 11] = std::array::from_fn(|k| _mm_set1_pd(self.yule_coeff_a[k]));
        let bb0 = _mm_set1_pd(self.butter_coeff_b[0]);
        let bb1 = _mm_set1_pd(self.butter_coeff_b[1]);
        let bb2 = _mm_set1_pd(self.butter_coeff_b[2]);
        let ba1 = _mm_set1_pd(self.butter_coeff_a[1]);
        let ba2 = _mm_set1_pd(self.butter_coeff_a[2]);

        let mut x_buf = [_mm_setzero_pd(); 10 + BLOCK];
        let mut y_buf = [_mm_setzero_pd(); 10 + BLOCK];
        for k in 0..10 {
            x_buf[k] = _mm_loadu_pd(self.yule_x[9 - k].as_ptr());
            y_buf[k] = _mm_loadu_pd(self.yule_y[9 - k].as_ptr());
        }
        let mut y1 = y_buf[9];
        let mut bx1 = _mm_loadu_pd(self.butter_x[0].as_ptr());
        let mut bx2 = _mm_loadu_pd(self.butter_x[1].as_ptr());
        let mut by1 = _mm_loadu_pd(self.butter_y[0].as_ptr());
        let mut by2 = _mm_loadu_pd(self.butter_y[1].as_ptr());

        let mut peak = self.peak;
        let win_target = self.window_samples;
        let mut win_cnt = self.cur_window_samples;
        let mut win_sum_vec = _mm_setzero_pd();
        let mut base_sum = self.cur_window_sum;

        let total_frames = pcm.len() / channels;
        let mut frame_idx = 0usize;
        let mut fir = [_mm_setzero_pd(); BLOCK];

        while frame_idx < total_frames {
            let win_rem = win_target - win_cnt;
            let n = win_rem.min(total_frames - frame_idx).min(BLOCK);
            let src = &pcm[frame_idx * channels..(frame_idx + n) * channels];

            // Pass 1: Load [L, R] -> f64x2 + peak scan (decoupled from feedback loop).
            for (i, frame) in src.chunks_exact(channels).enumerate() {
                let s_l = *frame.get_unchecked(0);
                let s_r = *frame.get_unchecked(1);
                let m = s_l.abs().max(s_r.abs());
                if m > peak {
                    peak = m;
                }
                x_buf[10 + i] = _mm_set_pd(s_r as f64, s_l as f64);
            }

            // Pass 2: Feedforward FIR across all n samples with zero loop-carried dependencies.
            for i in 0..n {
                let xb = &x_buf[i..i + 11];
                let s0 = _mm_add_pd(
                    _mm_mul_pd(xb[10], b_pairs[0]),
                    _mm_mul_pd(xb[9], b_pairs[1]),
                );
                let s1 = _mm_add_pd(
                    _mm_mul_pd(xb[8], b_pairs[2]),
                    _mm_mul_pd(xb[7], b_pairs[3]),
                );
                let s2 = _mm_add_pd(
                    _mm_mul_pd(xb[6], b_pairs[4]),
                    _mm_mul_pd(xb[5], b_pairs[5]),
                );
                let s3 = _mm_add_pd(
                    _mm_mul_pd(xb[4], b_pairs[6]),
                    _mm_mul_pd(xb[3], b_pairs[7]),
                );
                let s4 = _mm_add_pd(
                    _mm_mul_pd(xb[2], b_pairs[8]),
                    _mm_mul_pd(xb[1], b_pairs[9]),
                );
                let s5 = _mm_mul_pd(xb[0], b_pairs[10]);
                let pair_a = _mm_add_pd(_mm_add_pd(s0, s1), _mm_add_pd(s2, s3));
                let pair_b = _mm_add_pd(s4, s5);
                fir[i] = _mm_add_pd(pair_a, pair_b);
            }

            // Pass 3: Cascaded Yule IIR feedback + 2nd-order Butterworth + squared energy sum.
            for i in 0..n {
                let yb = &y_buf[i..i + 10];
                let fb_a = _mm_add_pd(
                    _mm_add_pd(_mm_mul_pd(yb[8], a_pairs[2]), _mm_mul_pd(yb[7], a_pairs[3])),
                    _mm_add_pd(_mm_mul_pd(yb[6], a_pairs[4]), _mm_mul_pd(yb[5], a_pairs[5])),
                );
                let fb_b = _mm_add_pd(
                    _mm_add_pd(_mm_mul_pd(yb[4], a_pairs[6]), _mm_mul_pd(yb[3], a_pairs[7])),
                    _mm_add_pd(_mm_mul_pd(yb[2], a_pairs[8]), _mm_mul_pd(yb[1], a_pairs[9])),
                );
                let fb_c = _mm_mul_pd(yb[0], a_pairs[10]);
                let fb_rest = _mm_add_pd(_mm_add_pd(fb_a, fb_b), fb_c);
                let pre_y = _mm_sub_pd(fir[i], fb_rest);
                let y0 = _mm_sub_pd(pre_y, _mm_mul_pd(y1, a_pairs[1]));
                y_buf[10 + i] = y0;
                y1 = y0;

                let b_pre = _mm_sub_pd(
                    _mm_add_pd(
                        _mm_add_pd(_mm_mul_pd(y0, bb0), _mm_mul_pd(bx1, bb1)),
                        _mm_mul_pd(bx2, bb2),
                    ),
                    _mm_mul_pd(by2, ba2),
                );
                let by0 = _mm_sub_pd(b_pre, _mm_mul_pd(by1, ba1));
                bx2 = bx1;
                bx1 = y0;
                by2 = by1;
                by1 = by0;

                win_sum_vec = _mm_add_pd(win_sum_vec, _mm_mul_pd(by0, by0));
            }

            x_buf.copy_within(n..10 + n, 0);
            y_buf.copy_within(n..10 + n, 0);

            frame_idx += n;
            win_cnt += n;

            if win_cnt >= win_target {
                let mut tmp = [0.0f64; 2];
                _mm_storeu_pd(tmp.as_mut_ptr(), win_sum_vec);
                let total_sum = base_sum + tmp[0] + tmp[1];
                self.push_window_energy(total_sum, win_cnt);
                win_sum_vec = _mm_setzero_pd();
                base_sum = 1e-16;
                win_cnt = 0;

                let mut dirty = false;
                for yslot in &mut y_buf[..10] {
                    let mut p = [0.0f64; 2];
                    _mm_storeu_pd(p.as_mut_ptr(), *yslot);
                    if p[0].abs() < Self::DENORMAL_FLUSH_THRESHOLD { p[0] = 0.0; dirty = true; }
                    if p[1].abs() < Self::DENORMAL_FLUSH_THRESHOLD { p[1] = 0.0; dirty = true; }
                    if dirty {
                        *yslot = _mm_loadu_pd(p.as_ptr());
                    }
                }
                y1 = y_buf[9];

                let mut bp = [[0.0f64; 2]; 2];
                _mm_storeu_pd(bp[0].as_mut_ptr(), by1);
                _mm_storeu_pd(bp[1].as_mut_ptr(), by2);
                let mut b_dirty = false;
                for p in &mut bp {
                    if p[0].abs() < Self::DENORMAL_FLUSH_THRESHOLD { p[0] = 0.0; b_dirty = true; }
                    if p[1].abs() < Self::DENORMAL_FLUSH_THRESHOLD { p[1] = 0.0; b_dirty = true; }
                }
                if b_dirty {
                    by1 = _mm_loadu_pd(bp[0].as_ptr());
                    by2 = _mm_loadu_pd(bp[1].as_ptr());
                }
            }
        }

        let mut rem_tmp = [0.0f64; 2];
        _mm_storeu_pd(rem_tmp.as_mut_ptr(), win_sum_vec);
        self.peak = peak;
        self.cur_window_samples = win_cnt;
        self.cur_window_sum = base_sum + rem_tmp[0] + rem_tmp[1];

        for k in 0..10 {
            _mm_storeu_pd(self.yule_x[9 - k].as_mut_ptr(), x_buf[k]);
            _mm_storeu_pd(self.yule_y[9 - k].as_mut_ptr(), y_buf[k]);
        }
        _mm_storeu_pd(self.butter_x[0].as_mut_ptr(), bx1);
        _mm_storeu_pd(self.butter_x[1].as_mut_ptr(), bx2);
        _mm_storeu_pd(self.butter_y[0].as_mut_ptr(), by1);
        _mm_storeu_pd(self.butter_y[1].as_mut_ptr(), by2);
        self.flush_denormals();
    }

    /// Scalar fallback processing an interleaved `pcm` slice with `channels >= 2` (first two channels).
    #[cfg(not(target_arch = "x86_64"))]
    fn push_stereo_scalar_slice(&mut self, pcm: &[f32], channels: usize) {
        let b = self.yule_coeff_b;
        let a = self.yule_coeff_a;
        let bb = self.butter_coeff_b;
        let ba = self.butter_coeff_a;

        let [mut x1, mut x2, mut x3, mut x4, mut x5, mut x6, mut x7, mut x8, mut x9, mut x10] =
            self.yule_x;
        let [mut y1, mut y2, mut y3, mut y4, mut y5, mut y6, mut y7, mut y8, mut y9, mut y10] =
            self.yule_y;
        let [mut bx1, mut bx2] = self.butter_x;
        let [mut by1, mut by2] = self.butter_y;

        let mut peak = self.peak;
        let win_target = self.window_samples;
        let mut win_cnt = self.cur_window_samples;
        let mut win_sum = self.cur_window_sum;

        for frame in pcm.chunks_exact(channels) {
            let s_l = frame[0];
            let s_r = frame[1];
            let max_s = s_l.abs().max(s_r.abs());
            if max_s > peak {
                peak = max_s;
            }
            let x0 = [s_l as f64, s_r as f64];
            let y0 = [
                (x0[0] * b[0] + x1[0] * b[1])
                    + (x2[0] * b[2] - y2[0] * a[2])
                    + (x3[0] * b[3] - y3[0] * a[3])
                    + (x4[0] * b[4] - y4[0] * a[4])
                    + (x5[0] * b[5] - y5[0] * a[5])
                    + (x6[0] * b[6] - y6[0] * a[6])
                    + (x7[0] * b[7] - y7[0] * a[7])
                    + (x8[0] * b[8] - y8[0] * a[8])
                    + (x9[0] * b[9] - y9[0] * a[9])
                    + (x10[0] * b[10] - y10[0] * a[10])
                    - y1[0] * a[1],
                (x0[1] * b[0] + x1[1] * b[1])
                    + (x2[1] * b[2] - y2[1] * a[2])
                    + (x3[1] * b[3] - y3[1] * a[3])
                    + (x4[1] * b[4] - y4[1] * a[4])
                    + (x5[1] * b[5] - y5[1] * a[5])
                    + (x6[1] * b[6] - y6[1] * a[6])
                    + (x7[1] * b[7] - y7[1] * a[7])
                    + (x8[1] * b[8] - y8[1] * a[8])
                    + (x9[1] * b[9] - y9[1] * a[9])
                    + (x10[1] * b[10] - y10[1] * a[10])
                    - y1[1] * a[1],
            ];
            x10 = x9; x9 = x8; x8 = x7; x7 = x6; x6 = x5;
            x5 = x4; x4 = x3; x3 = x2; x2 = x1; x1 = x0;
            y10 = y9; y9 = y8; y8 = y7; y7 = y6; y6 = y5;
            y5 = y4; y4 = y3; y3 = y2; y2 = y1; y1 = y0;

            let by0 = [
                y0[0] * bb[0] + bx1[0] * bb[1] + bx2[0] * bb[2] - by2[0] * ba[2] - by1[0] * ba[1],
                y0[1] * bb[0] + bx1[1] * bb[1] + bx2[1] * bb[2] - by2[1] * ba[2] - by1[1] * ba[1],
            ];
            bx2 = bx1; bx1 = y0;
            by2 = by1; by1 = by0;

            win_sum += by0[0] * by0[0] + by0[1] * by0[1];
            win_cnt += 1;
            if win_cnt >= win_target {
                self.push_window_energy(win_sum, win_cnt);
                win_sum = 1e-16;
                win_cnt = 0;
            }
        }

        self.peak = peak;
        self.cur_window_samples = win_cnt;
        self.cur_window_sum = win_sum;
        self.yule_x = [x1, x2, x3, x4, x5, x6, x7, x8, x9, x10];
        self.yule_y = [y1, y2, y3, y4, y5, y6, y7, y8, y9, y10];
        self.butter_x = [bx1, bx2];
        self.butter_y = [by1, by2];
        self.flush_denormals();
    }

    /// Feeds an un-clamped stereo frame (`s_l`, `s_r`) into the scanner.
    #[inline]
    pub fn push_stereo_frame(&mut self, s_l: f32, s_r: f32) {
        let pair = [s_l, s_r];
        self.push_slice(&pair, 2);
    }

    /// Quantizes the integrated energy (`window_sum` over `window_samples`) into the 0.01 dB histogram.
    #[inline]
    fn push_window_energy(&mut self, window_sum: f64, window_samples: usize) {
        if window_samples == 0 {
            return;
        }
        let rms = 10.0 * (window_sum / (window_samples as f64)).log10() + 90.0 - 3.0;
        let level = (rms * 100.0).floor() as i64;
        let idx = level.clamp(0, (HISTOGRAM_SLOTS - 1) as i64) as usize;
        self.histogram[idx] += 1;
    }

    /// Computes the final `(gain_db, peak)` tuple according to ReplayGain 1.0 (95th percentile).
    pub fn finalize(mut self) -> (f32, f32) {
        if self.cur_window_samples > 0 {
            self.push_window_energy(self.cur_window_sum, self.cur_window_samples);
        }

        let total_windows: u32 = self.histogram.iter().sum();
        if total_windows == 0 {
            crate::map_log!(
                4,
                "[REPLAYGAIN] Finalized empty stream (windows=0, peak={:.4})",
                self.peak
            );
            return (0.0, self.peak);
        }

        let mut loud_count = 0u32;
        let mut chosen_level = 0usize;
        for i in (0..HISTOGRAM_SLOTS).rev() {
            loud_count += self.histogram[i];
            if loud_count * 20 >= total_windows {
                chosen_level = i;
                break;
            }
        }

        let gain = (64.54 - (chosen_level as f64) / 100.0).clamp(-24.0, 64.0) as f32;
        crate::map_log!(
            4,
            "[REPLAYGAIN] Finalized: windows={} gain_db={:.2} peak={:.4}",
            total_windows,
            gain,
            self.peak
        );
        (gain, self.peak)
    }
}
