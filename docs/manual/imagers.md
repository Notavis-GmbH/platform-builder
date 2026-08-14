## Sensor mode
Different sensor modes are available. They define the resolution(Pixel depth), the number of lanes and the capture mode.


Available modes are found here
[Vision Components Guide](https://www.vision-components.com/fileadmin/external/documentation/hardware/VC_MIPI_Raspberry_PI/index.html#sensor-modes-description)


Only certain modes are support due to hardware restrictions from platform

### VC MIPI OV7251

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 10	| 2	| Streaming | 640x480| No |
| 1	| 8	| 2	| Streaming | 640x480| No |
| 2	| 10	|2|	External trigger |	640x480 | No | 
| 3	| 8	|2|	External trigger |	640x480 | No | 

### VC MIPI OV9281	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 10	| 2	| Streaming | 1280x800| Coming soon |
| 1	| 8	| 2	| Streaming | 1280x800| Coming soon  |
| 2	| 10	|2|	External trigger |	1280x800| No | 
| 3	| 8	|2|	External trigger |	1280x800| No |

### VC MIPI IMX178	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 3104x2076| No |
| 1	| 10	| 2	| Streaming | 3104x2076| No |
| 2	| 12	| 2	| Streaming | 3104x2076| No |
| 3	| 14	| 2	| Streaming | 3104x2076| No |
| 4	| 8	|2|	External trigger |	3104x2076 | No | 
| 5	| 10	|2|	External trigger |	3104x2076 | No |
| 6	| 12	|2|	External trigger |	3104x2076 | No |
| 7	| 14	|2|	External trigger |	3104x2076 | No |
| 8	| 8	| 4	| Streaming | 3104x2076| No | No |
| 9	| 10	| 4	| Streaming | 3104x2076| No | No |
| 10| 	12	| 4	| Streaming | 3104x2076| No | No |
| 11| 	14	| 4	| Streaming | 3104x2076| No | No |
| 12| 	8	|4|	External trigger |	3104x2076 | No |
| 13| 	10	|4|	External trigger |	3104x2076 | No |
| 14| 	12	|4|	External trigger |	3104x2076 | No |
| 15| 	14	|4|	External trigger |	3104x2076 | No |

### VC MIPI IMX183	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 5440x3648|  Yes |
| 1	| 10	| 2	| Streaming | 5440x3648|  Yes |
| 2	| 12	| 2	| Streaming | 5440x3648|  Not tested |
| 3	| 8	|2|	External trigger |	5440x3648 | No |
| 4	| 10	|2|	External trigger |	5440x3648 | No | 
| 5	| 12	|2|	External trigger |	5440x3648 | No |
| 6	| 8	| 4	| Streaming | 5440x3648| No |
| 7	| 10	| 4	| Streaming | 5440x3648| No |
| 8	| 12	| 4	| Streaming | 5440x3648| No |
| 9	| 8	|4|	External trigger |	5440x3648 | No |
| 10| 	10	|4|	External trigger |	5440x3648 | No |
| 11| 	12	|4|	External trigger |	5440x3648 | No |

### VC MIPI IMX226	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 3840x3046|   Not tested |
| 1	| 10	| 2	| Streaming | 3840x3046|  Not tested |
| 2	| 12	| 2	| Streaming | 3840x3046|  Not tested |
| 3	| 8	|2|	External trigger |	3840x3046 | No |
| 4	| 10	|2|	External trigger |	3840x3046 | No | 
| 5	| 12	|2|	External trigger |	3840x3046 | No |
| 6	| 8	| 4	| Streaming | 3840x3046| No |
| 7	| 10	| 4	| Streaming | 3840x3046| No |
| 8	| 12	| 4	| Streaming | 3840x3046| No |
| 9	| 8	|4|	External trigger |	3840x3046 | No |
| 10| 	10	|4|	External trigger |	3840x3046 | No |
| 11| 	12	|4|	External trigger |	3840x3046 | No |

### VC MIPI IMX250	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 2432x2048| No |
| 1	| 10	| 2	| Streaming | 2432x2048| Yes |
| 2	| 12	| 2	| Streaming | 2432x2048| No |
| 3	| 8	|2|	External trigger |	2432x2048 | No |
| 4	| 10	|2|	External trigger |	2432x2048 | No | 
| 5	| 12	|2|	External trigger |	2432x2048 | No |
| 6	| 8	| 4	| Streaming | 2432x2048| No | No |
| 7	| 10	| 4	| Streaming | 2432x2048| No | No |
| 8	| 12	| 4	| Streaming | 2432x2048| No | No |
| 9	| 8	|4|	External trigger |	2432x2048 | No |
| 10| 	10	|4|	External trigger |	2432x2048 | No |
| 11| 	12	|4|	External trigger |	2432x2048 | No |

### VC MIPI IMX252	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 2048x1536|  No |
| 1	| 10	| 2	| Streaming | 2048x1536|  No |
| 2	| 12	| 2	| Streaming | 2048x1536|  No |
| 3	| 8	|2|	External trigger |	2048x1536 | No |
| 4	| 10	|2|	External trigger |	2048x1536 | No | 
| 5	| 12	|2|	External trigger |	2048x1536 | No |
| 6	| 8	| 4	| Streaming | 2048x1536|  No | No |
| 7	| 10	| 4	| Streaming | 2048x1536|  No | No |
| 8	| 12	| 4	| Streaming | 2048x1536|  No | No |
| 9	| 8	|4|	External trigger |	2048x1536 | No |
| 10| 	10	|4|	External trigger |	2048x1536 | No |
| 11| 	12	|4|	External trigger |	2048x1536 | No |

### VC MIPI IMX264	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 2432x2048| No |
| 1	| 10	| 2	| Streaming | 2432x2048| No |
| 2	| 12	| 2	| Streaming | 2432x2048| No |
| 3	| 8	|2|	External trigger |	2432x2048 | No |
| 4	| 10	|2|	External trigger |	2432x2048 | No | 
| 5	| 12	|2|	External trigger |	2432x2048 | No |

### VC MIPI IMX265	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 2048x1536|  No |
| 1	| 10	| 2	| Streaming | 2048x1536|  No |
| 2	| 12	| 2	| Streaming | 2048x1536|  No |
| 3	| 8	|2|	External trigger |	2048x1536 | No |
| 4	| 10	|2|	External trigger |	2048x1536 | No | 
| 5	| 12	|2|	External trigger |	2048x1536 | No |

### VC MIPI IMX273	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 1440x1080|   Not tested |
| 1	| 10	| 2	| Streaming | 1440x1080|   Not tested |
| 2	| 12	| 2	| Streaming | 1440x1080|   Not tested |
| 3	| 8	|2|	External trigger |	1440x1080 | No |
| 4	| 10	|2|	External trigger |	1440x1080 | No | 
| 5	| 12	|2|	External trigger |	1440x1080 | No |
| 6	| 8	| 4	| Streaming | 1440x1080| No |
| 7	| 10	| 4	| Streaming | 1440x1080| No |
| 8	| 12	| 4	| Streaming | 1440x1080| No |
| 9	| 8	|4|	External trigger |	1440x1080 | No |
| 10| 	10	|4|	External trigger |	1440x1080 | No |
| 11| 	12	|4|	External trigger |	1440x1080 | No |
| 12| 	8	| 2	| Streaming | 720x540 (binning)|  Not tested |
| 13| 	10	| 2	| Streaming | 720x540 (binning)|  Not tested |
| 14| 	12	| 2	| Streaming | 720x540 (binning)|  Not tested |
| 15| 	8	|2|	External trigger |	720x540 (binning) | No |
| 16| 	10	|2|	External trigger |	720x540 (binning) | No |
| 17| 	12	|2|	External trigger |	720x540 (binning) | No |
| 18| 	8	| 4	| Streaming | 720x540 (binning)| No |
| 19| 	10	| 4	| Streaming | 720x540 (binning)| No |
| 20| 	12	| 4	| Streaming | 720x540 (binning)| No |
| 21| 	8	|4|	External trigger |	720x540 (binning) | No |
| 22| 	10	|4|	External trigger |	720x540 (binning) | No |
| 23| 	12	|4|	External trigger |	720x540 (binning) | No |

### VC MIPI IMX290	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 10	| 2	| Streaming | 1920x1080|  Not tested |
| 1	| 10	| 4	| Streaming | 1920x1080| No |

### VC MIPI IMX296	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 10	| 1	| Streaming | 1440x1080|  Not tested |
| 1	| 10	|1|	External trigger |	1440x1080 | No |
| 2	| 10	| 1	| Streaming | 720x540 (binning)|  Not tested |
| 3	| 10	|1|	External trigger |	720x540 (binning) | No |

### VC MIPI IMX296 C	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 10	| 1	| Streaming | 1440x1080|  Not tested |
| 1	| 10	|1|	External trigger |	1440x1080 | No |

### VC MIPI IMX297	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 10	| 1	| Streaming | 720x540|  Not tested |
| 1	| 10	|1|	External trigger |	720x540 | No |

### VC MIPI IMX327 C	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 10	| 2	| Streaming | 1920x1080| yes | 
| 1	| 10	| 4	| Streaming | 1920x1080| No |

### VC MIPI IMX335	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 10	| 2	| Streaming | 2560x1964| Yes |
| 1	| 10	| 2	| Streaming | 2560x1964| Not tested |
| 2	| 12	| 2	| Streaming | 2560x1964| Not tested |
| 3	| 12	| 2	| Streaming | 2560x1964| Not tested |
| 4	| 10	| 4	| Streaming | 2560x1964| No |
| 5	| 10	| 4	| Streaming | 2560x1964| No |
| 6	| 12	| 4	| Streaming | 2560x1964| No |
| 7	| 12	| 4	| Streaming | 2560x1964| No |

### VC MIPI IMX392	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 1920x1200| Not tested |
| 1	| 10	| 2	| Streaming | 1920x1200| Not tested |
| 2	| 12	| 2	| Streaming | 1920x1200| Not tested |
| 3	| 8	|2|	External trigger |	1920x1200 | No |
| 4	| 10	|2|	External trigger |	1920x1200 | No | 
| 5	| 12	|2|	External trigger |	1920x1200 | No |
| 6	| 8	| 4	| Streaming | 1920x1200| No |
| 7	| 10	| 4	| Streaming | 1920x1200| No |
| 8	| 12	| 4	| Streaming | 1920x1200| No |
| 9	| 8	|4|	External trigger |	1920x1200 | No |
| 10| 	10	|4|	External trigger |	1920x1200 | No |
| 11| 	12	|4|	External trigger |	1920x1200 | No |

### VC MIPI IMX412 C	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 10	| 2	| Streaming | 4056x3040|  Not tested |
| 1	| 10	| 4	| Streaming | 4056x3040| No |

### VC MIPI IMX415 C	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 10	| 2	| Streaming | 3864x2192|  Not tested |
| 1	| 10	| 4	| Streaming | 3864x2192| No |

### VC MIPI IMX462 C	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 10	| 2	| Streaming | 1920x1080| Yes |
| 1	| 10	| 4	| Streaming | 1920x1080| No |

### VC MIPI IMX565	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 4128x3008|   Not tested |
| 1	| 10	| 2	| Streaming | 4128x3008|   Not tested |
| 2	| 12	| 2	| Streaming | 4128x3008|   Not tested |
| 3	| 8	|2|	External trigger |	4128x3008 | No |
| 4	| 10	|2|	External trigger |	4128x3008 | No | 
| 5	| 12	|2|	External trigger |	4128x3008 | No |
| 6	| 8	| 4	| Streaming | 4128x3008| No |
| 7	| 10	| 4	| Streaming | 4128x3008| No |
| 8	| 12	| 4	| Streaming | 4128x3008| No |
| 9	| 8	|4|	External trigger |	4128x3008 | No |
| 10| 	10	|4|	External trigger |	4128x3008 | No |
| 11| 	12	|4|	External trigger |	4128x3008 | No |

### VC MIPI IMX566	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 2848x2840|  Not tested |
| 1	| 10	| 2	| Streaming | 2848x2840|  Not tested |
| 2	| 12	| 2	| Streaming | 2848x2840|  Not tested |
| 3	| 8	|2|	External trigger |	2848x2840 | No |
| 4	| 10	|2|	External trigger |	2848x2840 | No | 
| 5	| 12	|2|	External trigger |	2848x2840 | No |
| 6	| 8	| 4	| Streaming | 2848x2840| No |
| 7	| 10	| 4	| Streaming | 2848x2840| No |
| 8	| 12	| 4	| Streaming | 2848x2840| No |
| 9	| 8	|4|	External trigger |	2848x2840 | No |
| 10| 	10	|4|	External trigger |	2848x2840 | No |
| 11| 	12	|4|	External trigger |	2848x2840 | No |

### VC MIPI IMX567	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 2432x2048| Yes |
| 1	| 10	| 2	| Streaming | 2432x2048| No |
| 2	| 12	| 2	| Streaming | 2432x2048| No |
| 3	| 8	|2|	External trigger |	2432x2048 | No |
| 4	| 10	|2|	External trigger |	2432x2048 | No | 
| 5	| 12	|2|	External trigger |	2432x2048 | No |
| 6	| 8	| 4	| Streaming | 2432x2048| No | No |
| 7	| 10	| 4	| Streaming | 2432x2048| No | No |
| 8	| 12	| 4	| Streaming | 2432x2048| No | No |
| 9	| 8	|4|	External trigger |	2432x2048 | No |
| 10| 	10	|4|	External trigger |	2432x2048 | No |
| 11| 	12	|4|	External trigger |	2432x2048 | No |

### VC MIPI IMX568	

| Mode | Image format (bits) | Lanes	| Capture mode |	Resolution |  Supported on platform |
| --- | --- | --- | --- | --- | --- |
| 0	| 8	| 2	| Streaming | 2432x2048| Yes |
| 1	| 10	| 2	| Streaming | 2432x2048| No |
| 2	| 12	| 2	| Streaming | 2432x2048| No |
| 3	| 8	|2|	External trigger |	2432x2048 | No |
| 4	| 10	|2|	External trigger |	2432x2048 | No | 
| 5	| 12	|2|	External trigger |	2432x2048 | No |
| 6	| 8	| 4	| Streaming | 2432x2048| No | No |
| 7	| 10	| 4	| Streaming | 2432x2048| No | No |
| 8	| 12	| 4	| Streaming | 2432x2048| No | No |
| 9	| 8	|4|	External trigger |	2432x2048 | No |
| 10| 	10	|4|	External trigger |	2432x2048 | No |
| 11| 	12	|4|	External trigger |	2432x2048 | No |