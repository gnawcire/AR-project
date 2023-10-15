/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Main view controller for the AR experience.
*/

import ARKit
import SceneKit
import UIKit
import FirebaseCore
import FirebaseFirestore


class ViewController: UIViewController, ARSCNViewDelegate {
    
    @IBOutlet var sceneView: ARSCNView!
    
    @IBOutlet weak var blurView: UIVisualEffectView!
    
    @IBOutlet weak var buildingButton: UIButton!
    
    
    
    /// The view controller that displays the status and "restart experience" UI.
    lazy var statusViewController: StatusViewController = {
        return children.lazy.compactMap({ $0 as? StatusViewController }).first!
    }()
    
    /// A serial queue for thread safety when modifying the SceneKit node graph.
    let updateQueue = DispatchQueue(label: Bundle.main.bundleIdentifier! +
        ".serialSceneKitQueue")
    
    /// Convenience accessor for the session owned by ARSCNView.
    var session: ARSession {
        return sceneView.session
    }
    
    // MARK: - View Controller Life Cycle
    var db: Firestore!
    override func viewDidLoad() {
        super.viewDidLoad()
        
        sceneView.delegate = self
        sceneView.session.delegate = self
        
        buildingButton.isHidden = true
        // Hook up status view controller callback(s).
        statusViewController.restartExperienceHandler = { [unowned self] in
            self.restartExperience()
        }
        db = Firestore.firestore()
    }

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		
		// Prevent the screen from being dimmed to avoid interuppting the AR experience.
		UIApplication.shared.isIdleTimerDisabled = true

        // Start the AR experience
        resetTracking()
	}
	
	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)

        session.pause()
	}

    // MARK: - Session management (Image detection setup)
    
    /// Prevents restarting the session while a restart is in progress.
    var isRestartAvailable = true

    /// Creates a new AR configuration to run on the `session`.
    /// - Tag: ARReferenceImage-Loading
    var descriptionOfCur: String = ""
    var nameOfCur: String = ""
    func resetTracking() {
        //old code to get referenceimages from assets
//        guard let referenceImages = ARReferenceImage.referenceImages(inGroupNamed: "AR Resources", bundle: nil) else {
//            fatalError("Missing expected asset catalog resources.")
//        }
        
        let configuration = ARWorldTrackingConfiguration()
        
        db.collection("Images").getDocuments() { (querySnapshot, err) in
            if let err = err {
                print("ERROR getting documents: \(err)")
            } else {
                DispatchQueue.global().async {
                    if configuration.detectionImages.isEmpty {
                        var imagesSet: [ARReferenceImage] = []
                        for document in querySnapshot!.documents {
                            print("\(document.documentID) => \(document.data())")
                            print(document.data()["URL"]!)
                            let urlstring: String = document.data()["URL"]! as! String
                            let theURL = URL(string: urlstring)
                            do {
                                let imageData = try Data(contentsOf: theURL!)
                                let image = UIImage(data: imageData)
                                print("image loaded")
                                var cgFloat: CGFloat?
                                if let doubleValue = Double(document.data()["width"] as! String) {
                                    cgFloat = CGFloat(doubleValue)
                                }
                                let referenceImage = ARReferenceImage((image?.cgImage)!, orientation: .up, physicalWidth: cgFloat!)
                                referenceImage.name = document.data()["name"] as? String
                                imagesSet.append(referenceImage)
                            } catch {
                                print("ERROR")
                            }
                        }
                        configuration.detectionImages = Set(imagesSet)
                    }
                    self.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                    self.statusViewController.scheduleMessage("Look around to detect images", inSeconds: 7.5, messageType: .contentPlacement)
                }
            }
        }
        
        //former code to get images from assets, not needed.
//        configuration.detectionImages = referenceImages

	}

    // MARK: - ARSCNViewDelegate (Image detection results)
    /// - Tag: ARImageAnchor-Visualizing
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        sceneView.session.remove(anchor: anchor)
        guard let imageAnchor = anchor as? ARImageAnchor else { return }
        let referenceImage = imageAnchor.referenceImage
        updateQueue.async {
            
            // Create a plane to visualize the initial position of the detected image.
            let plane = SCNPlane(width: referenceImage.physicalSize.width,
                                 height: referenceImage.physicalSize.height)
            let planeNode = SCNNode(geometry: plane)
            planeNode.opacity = 0.25
            
            /*
             `SCNPlane` is vertically oriented in its local coordinate space, but
             `ARImageAnchor` assumes the image is horizontal in its local space, so
             rotate the plane to match.
             */
            planeNode.eulerAngles.x = -.pi / 2
            
            /*
             Image anchors are not tracked after initial detection, so create an
             animation that limits the duration for which the plane visualization appears.
             */
            planeNode.runAction(self.imageHighlightAction)
            
            // Add the plane visualization to the scene.
            node.addChildNode(planeNode)
        }

        DispatchQueue.main.async {
            let imageName = referenceImage.name ?? ""
            self.statusViewController.cancelAllScheduledMessages()
            self.statusViewController.showMessage("Detected image “\(imageName)”")
            self.db.collection("ImageDescriptions").getDocuments() {(querySnapshot, err) in
                if let err = err {
                    print("ERROR: \(err)")
                } else {
                    for document in querySnapshot!.documents {
                        if document.data()["name"] as! String == imageName{
                            self.descriptionOfCur = document.data()["description"] as! String
                            self.nameOfCur = imageName
                            self.buildingButton.setTitle(imageName, for: .normal)
                            self.buildingButton.titleLabel?.font = UIFont(name: "Kefa-Regular", size: 30)


                        }
                    }
                }
            }
            self.buttonAppear()
        }
    }

    var imageHighlightAction: SCNAction {
        return .sequence([
            .wait(duration: 0.25),
            .fadeOpacity(to: 0.85, duration: 0.25),
            .fadeOpacity(to: 0.15, duration: 0.25),
            .fadeOpacity(to: 0.85, duration: 0.25),
            .fadeOut(duration: 0.5),
            .removeFromParentNode()
        ])
    }
    
    func buttonAppear() {
        buildingButton.isHidden = false
        buildingButton.layer.cornerRadius = buildingButton.frame.size.height / 2
        buildingButton.clipsToBounds = true

    }
    
    @IBOutlet weak var buildingInfoView: UIView!
    @IBOutlet weak var bottomConstraint: NSLayoutConstraint!
    var expanded: Bool = false
    
    @IBOutlet weak var bottomConstraintForText: NSLayoutConstraint!
    @IBOutlet weak var descriptionText: UILabel!
    @IBOutlet weak var topConstraintText: NSLayoutConstraint!
    @IBOutlet weak var topConstraintForText: NSLayoutConstraint!
    @IBAction func expandBuilding(_ sender: Any) {
        if expanded{
            bottomConstraint.constant = 0
            UIView.animate(withDuration: 0.5) {
                self.buildingInfoView.backgroundColor = UIColor(red: 0.941, green: 0.941, blue: 0.941, alpha: 0)
                self.descriptionText.text = ""
                self.view.layoutIfNeeded()
            }
            expanded = false
            return
        }
        expanded = true
        bottomConstraint.constant = 240
        bottomConstraintForText.constant = 50
        topConstraintText.constant = 50
        UIView.animate(withDuration: 0.5) {
            self.buildingInfoView.backgroundColor = UIColor(red: 0.941, green: 0.941, blue: 0.941, alpha: 1)
            self.descriptionText.text = self.descriptionOfCur
            self.descriptionText.textColor = .black
            self.view.layoutIfNeeded()
        }
        
    }
    @IBOutlet weak var buildingExpanded: UIView!
    
}
